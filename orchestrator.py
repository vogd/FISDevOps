#!/usr/bin/env python3
"""
FIS Chaos Experiment Orchestrator with AWS DevOps Agent Integration.

Captures full timeline: experiment start, agent trigger, RCA completion, S3 write.
All errors and exceptions from DevOps Agent are recorded in the result.
"""

import argparse
import json
import os
import random
import sys
import time
import traceback
from datetime import datetime, timezone

import boto3

fis = boto3.client("fis")
cw = boto3.client("cloudwatch")
s3 = boto3.client("s3")
_devops_clients = {}


def get_devops_client(region="us-east-1"):
    if region not in _devops_clients:
        _devops_clients[region] = boto3.client("devops-agent", region_name=region)
    return _devops_clients[region]
bedrock = boto3.client("bedrock-runtime", region_name="us-west-2")


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    with open(path) as f:
        return json.load(f)


# --- FIS ---

def start_experiment(template_id):
    resp = fis.start_experiment(experimentTemplateId=template_id)
    exp_id = resp["experiment"]["id"]
    return exp_id


def wait_for_experiment(experiment_id, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = fis.get_experiment(id=experiment_id)["experiment"]["state"]["status"]
        if status in ("completed", "stopped", "failed"):
            return status
        time.sleep(10)
    return "timeout"


# --- DevOps Agent: Webhook via Proxy ---

def trigger_investigation(endpoint_id, experiment, failover=False):
    """Send incident via EventBridge Global Endpoint, or directly to secondary bus if failover=True."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    incident_id = f"fis-chaos-{experiment['id']}-{int(time.time())}"
    detail = {
        "eventType": "incident",
        "incidentId": incident_id,
        "action": "created",
        "priority": "HIGH",
        "title": f"[{incident_id}] {experiment['id']} failure detected",
        "description": (
            f"Incident {incident_id}: Service '{experiment['id']}-svc' is experiencing failures "
            f"in {os.environ.get('AWS_DEFAULT_REGION', 'us-west-2')}. Investigate root cause on EKS cluster chaos-cluster, namespace app."
        ),
        "timestamp": timestamp,
        "service": f"{experiment['id']}-svc",
    }

    entry = {
        "Source": "fis-chaos",
        "DetailType": "incident",
        "Detail": json.dumps(detail),
        "EventBusName": "fis-chaos-global-inbound",
    }

    if failover:
        # Send directly to secondary region's bus (bypass Global Endpoint)
        sm = boto3.client("secretsmanager", region_name=os.environ.get("AWS_DEFAULT_REGION", "eu-west-1"))
        config = json.loads(sm.get_secret_value(SecretId="fis-chaos/webhook-proxy")["SecretString"])
        # Support both old flat format and new endpoints list
        if "endpoints" in config and len(config["endpoints"]) > 1:
            secondary_region = config["endpoints"][1]["region"]
        else:
            secondary_region = config.get("secondary_region", os.environ.get("AWS_DEFAULT_REGION", "eu-west-1"))
        detail["force_target"] = secondary_region
        entry["Detail"] = json.dumps(detail)
        events_client = boto3.client("events", region_name=secondary_region)
        resp = events_client.put_events(Entries=[entry])
    else:
        events_client = boto3.client("events")
        resp = events_client.put_events(EndpointId=endpoint_id, Entries=[entry])

    failed = resp.get("FailedEntryCount", 0)
    if failed:
        error_msg = resp["Entries"][0].get("ErrorMessage", "Unknown")
        raise RuntimeError(f"PutEvents failed: {error_msg}")
    return incident_id


# --- DevOps Agent: Poll + RCA ---

_sqs_clients = {}


def get_sqs_client(queue_url):
    """Get or create SQS client for the region implied by the queue URL."""
    # Extract region from URL: https://sqs.<region>.amazonaws.com/...
    region = queue_url.split(".")[1] if "sqs." in queue_url else "us-east-1"
    if region not in _sqs_clients:
        _sqs_clients[region] = boto3.client("sqs", region_name=region)
    return _sqs_clients[region]


def wait_for_investigation_ddb(incident_id, timeout=1500):
    """Wait for investigation completion by polling DynamoDB."""
    print(f"  [DDB] Waiting for investigation status (incident={incident_id})...")
    dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_DEFAULT_REGION", "us-west-2"))
    table = dynamodb.Table("fis-chaos-investigations")
    deadline = time.time() + timeout

    last_status = ""
    while time.time() < deadline:
        try:
            resp = table.get_item(Key={"incident_id": incident_id})
            item = resp.get("Item")
            if item:
                status = item.get("detail_type", "")
                if status != last_status:
                    print(f"  [DDB] {now_iso()} {status}: task={item.get('task_id','')} space={item.get('space_id','')[:8]}...")
                    last_status = status
                if "Completed" in status:
                    return (
                        item.get("task_id", ""),
                        item.get("execution_id", ""),
                        "COMPLETED",
                        "",
                        item.get("space_id", ""),
                        item.get("region", ""),
                    )
                elif "Linked" in status:
                    # Follow the primary task — poll until its investigation completes
                    task_id = item.get("task_id", "")
                    space_id = item.get("space_id", "")
                    region = item.get("region", os.environ.get("AWS_DEFAULT_REGION", "us-west-2"))
                    print(f"  [DDB] LINKED — following primary task via API...")
                    try:
                        devops_client = get_devops_client(region)
                        # Resolve primary task ID
                        primary_id = None
                        tasks = devops_client.list_backlog_tasks(agentSpaceId=space_id, limit=20)
                        for t in tasks.get("tasks", []):
                            if t["taskId"] == task_id and t.get("primaryTaskId"):
                                primary_id = t["primaryTaskId"]
                                break
                        if not primary_id:
                            print(f"  [DDB] LINKED but no primaryTaskId found for {task_id}")
                        else:
                            print(f"  [DDB] LINKED → primary task {primary_id}, polling for completion...")
                            # Poll primary task executions until COMPLETED or timeout
                            while time.time() < deadline:
                                execs = devops_client.list_executions(agentSpaceId=space_id, taskId=primary_id)
                                for ex in execs.get("executions", []):
                                    if ex["executionStatus"] == "COMPLETED":
                                        print(f"  [DDB] LINKED → primary {primary_id} COMPLETED")
                                        return primary_id, ex["executionId"], "COMPLETED (via LINKED)", "", space_id, region
                                time.sleep(10)
                    except Exception as e:
                        print(f"  [DDB] LINKED follow error: {e}")
                elif status in ("Investigation Failed", "Investigation Timed Out", "Investigation Cancelled"):
                    return (
                        item.get("task_id", ""),
                        item.get("execution_id", ""),
                        item.get("status", status),
                        "",
                        item.get("space_id", ""),
                        item.get("region", ""),
                    )
        except Exception as e:
            print(f"  [DDB] Error: {e}")
        time.sleep(5)

    print(f"  [DDB] Timeout after {timeout}s")
    return ("", "", "POLL_TIMEOUT", "", "", "")


def wait_for_investigation(queue_urls, agent_space_id, agent_region="us-east-1", timeout=1500, since_ts=None):
    """Wait for investigation completion by polling one or more SQS queues."""
    print(f"  [SQS] Waiting for investigation events...")
    # Normalize to list of queue URLs
    if isinstance(queue_urls, str):
        queue_urls = [queue_urls]
    devops_client = get_devops_client(agent_region)
    deadline = time.time() + timeout
    since = since_ts or time.time()

    while time.time() < deadline:
        for queue_url in queue_urls:
            remaining = max(1, int(deadline - time.time()))
            if remaining <= 0:
                break
            try:
                sqs_client = get_sqs_client(queue_url)
                resp = sqs_client.receive_message(
                    QueueUrl=queue_url,
                    MaxNumberOfMessages=10,
                    WaitTimeSeconds=min(5, remaining),
                )
                for msg in resp.get("Messages", []):
                    try:
                        eb_event = json.loads(msg["Body"])
                        detail = eb_event.get("detail", {})
                        meta = detail.get("metadata", {})
                        data = detail.get("data", {})

                        # Reject stale events (older than when we triggered)
                        event_time = eb_event.get("time", "")
                        if event_time:
                            from datetime import datetime as dt
                            try:
                                evt_ts = dt.fromisoformat(event_time.replace("Z", "+00:00")).timestamp()
                                if evt_ts < since - 5:
                                    sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])
                                    continue
                            except (ValueError, TypeError):
                                pass

                        detail_type = eb_event.get("detail-type", "")
                        task_id = meta.get("task_id", "")
                        exec_id = meta.get("execution_id", "")
                        status = data.get("status", "")
                        event_space_id = meta.get("agent_space_id", "")

                        print(f"  [SQS] {now_iso()} {detail_type}: task={task_id} space={event_space_id[:8]}... status={status}")

                        sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])

                        if detail_type == "Investigation Completed":
                            # Update agent_region based on which queue responded
                            resp_region = queue_url.split(".")[1] if ".sqs." not in queue_url else queue_url.split("sqs.")[1].split(".")[0]
                            return task_id, exec_id, "COMPLETED", data.get("summary_record_id", ""), event_space_id, resp_region
                        elif detail_type in ("Investigation Failed", "Investigation Timed Out", "Investigation Cancelled"):
                            return task_id, exec_id, status, "", event_space_id, agent_region
                        elif detail_type == "Investigation Linked":
                            try:
                                space = event_space_id or agent_space_id
                                dc = get_devops_client(agent_region)
                                tasks = dc.list_backlog_tasks(agentSpaceId=space, limit=20)
                                for t in tasks.get("tasks", []):
                                    if t["taskId"] == task_id and t.get("primaryTaskId"):
                                        primary_id = t["primaryTaskId"]
                                        execs = dc.list_executions(agentSpaceId=space, taskId=primary_id)
                                        for ex in execs.get("executions", []):
                                            if ex["executionStatus"] == "COMPLETED":
                                                print(f"  [SQS] LINKED → primary {primary_id}")
                                                return primary_id, ex["executionId"], "COMPLETED (via LINKED)", "", space, agent_region
                            except Exception:
                                pass
                    except (json.JSONDecodeError, KeyError):
                        sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])
                        continue
            except Exception as e:
                print(f"  [SQS] Error polling {queue_url}: {e}")
                time.sleep(2)

    print(f"  [SQS] Timeout, falling back to API poll...")
    return _fallback_api_poll(agent_space_id, agent_region, time.time() - timeout) + ("", agent_region)


def wait_for_mitigation(queue_url, agent_space_id, task_id=None, timeout=300):
    """Wait for Mitigation Completed event on SQS, filtered by task_id."""
    print(f"  [SQS] Waiting for mitigation events ({timeout}s timeout)...")
    sqs_client = get_sqs_client(queue_url)
    deadline = time.time() + timeout

    while time.time() < deadline:
        remaining = max(1, int(deadline - time.time()))
        try:
            resp = sqs_client.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=min(20, remaining),
            )
            for msg in resp.get("Messages", []):
                try:
                    eb_event = json.loads(msg["Body"])
                    detail = eb_event.get("detail", {})
                    meta = detail.get("metadata", {})
                    data = detail.get("data", {})

                    if meta.get("agent_space_id") != agent_space_id:
                        continue

                    # Skip events from other tasks
                    if task_id and meta.get("task_id") != task_id:
                        sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])
                        continue

                    detail_type = eb_event.get("detail-type", "")
                    sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])

                    if detail_type == "Mitigation Completed":
                        return "COMPLETED", meta.get("execution_id", ""), data.get("summary_record_id", "")
                    elif detail_type in ("Mitigation Failed", "Mitigation Timed Out", "Mitigation Cancelled"):
                        return data.get("status", detail_type), meta.get("execution_id", ""), ""
                    elif detail_type == "Mitigation In Progress":
                        print(f"  [SQS] {now_iso()} Mitigation in progress...")
                except (json.JSONDecodeError, KeyError):
                    sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=msg["ReceiptHandle"])
        except Exception as e:
            print(f"  [SQS] Mitigation poll error: {e}")
            time.sleep(5)

    return None, None, None


def request_mitigation(agent_space_id, agent_region, task_id):
    """Request mitigation via ACP chat — steers the agent to generate a mitigation plan."""
    from aws_devops_agent import ACPClient

    print(f"  [ACP] Requesting mitigation for task {task_id}...")
    try:
        user_id = os.environ.get("DEVOPS_AGENT_USER_ID") or \
            boto3.client("sts").get_caller_identity()["Arn"].split("/")[-1]
        with ACPClient(region=agent_region, space_id=agent_space_id,
                       user_id=user_id) as client:
            response = client.prompt_sync(
                f"For investigation task {task_id}, generate a mitigation plan to resolve the issue. "
                f"The investigation is complete — please propose concrete remediation steps.",
                timeout=300,
            )
            print(f"  [ACP] Mitigation requested ({len(response)} chars response)")
            return response
    except Exception as e:
        print(f"  [ACP] Mitigation request failed: {e}")
        return None


def _fallback_api_poll(agent_space_id, agent_region, since_ts):
    """Paginated API check as fallback. Follows LINKED chains to primary tasks."""
    devops_client = get_devops_client(agent_region)
    since_dt = datetime.fromtimestamp(since_ts, tz=timezone.utc)
    try:
        all_tasks = []
        resp = devops_client.list_backlog_tasks(agentSpaceId=agent_space_id, limit=20)
        all_tasks.extend(resp.get("tasks", []))
        while resp.get("nextToken"):
            resp = devops_client.list_backlog_tasks(agentSpaceId=agent_space_id, limit=20, nextToken=resp["nextToken"])
            all_tasks.extend(resp.get("tasks", []))

        task_map = {t["taskId"]: t for t in all_tasks}

        for task in all_tasks:
            if task.get("taskType") != "INVESTIGATION":
                continue
            created = task.get("createdAt")
            if isinstance(created, (int, float)):
                created = datetime.fromtimestamp(created, tz=timezone.utc)
            if created and created < since_dt:
                continue

            status = task.get("status")
            if status == "COMPLETED":
                return task["taskId"], task.get("executionId", ""), "COMPLETED", ""
            elif status == "LINKED":
                primary_id = task.get("primaryTaskId")
                if primary_id:
                    primary = task_map.get(primary_id)
                    if primary and primary.get("status") == "COMPLETED":
                        print(f"  [API] LINKED → primary {primary_id} (from task list)")
                        return primary_id, primary.get("executionId", ""), "COMPLETED (via LINKED)", ""
                    try:
                        execs = devops_client.list_executions(agentSpaceId=agent_space_id, taskId=primary_id)
                        for ex in execs.get("executions", []):
                            if ex["executionStatus"] == "COMPLETED":
                                print(f"  [API] LINKED → primary {primary_id} (from executions)")
                                return primary_id, ex["executionId"], "COMPLETED (via LINKED)", ""
                    except Exception:
                        pass
    except Exception:
        pass
    return None, None, "POLL_TIMEOUT", ""


def get_rca_summary(agent_space_id, execution_id, agent_region="us-east-1"):
    client = get_devops_client(agent_region)
    resp = client.list_journal_records(
        agentSpaceId=agent_space_id,
        executionId=execution_id,
        recordType="investigation_summary_md",
        limit=1,
    )
    records = resp.get("records", [])
    if records:
        content = records[0].get("content", "")
        return json.dumps(content) if isinstance(content, dict) else str(content)
    return ""


def get_structured_rca(agent_space_id, execution_id, agent_region="us-east-1"):
    """Extract structured data from investigation_summary JSON record."""
    client = get_devops_client(agent_region)
    out = {"resources": [], "cascade_graph": [], "findings": [], "symptoms": [], "gaps": []}
    try:
        resp = client.list_journal_records(
            agentSpaceId=agent_space_id,
            executionId=execution_id,
            recordType="investigation_summary",
            limit=1,
        )
        records = resp.get("records", [])
        if not records:
            return out
        content = records[0].get("content", {})
        if isinstance(content, str):
            content = json.loads(content)

        all_resources = set()
        for f in content.get("findings", []):
            for r in f.get("related_resources", []):
                all_resources.add(str(r))
            out["findings"].append({
                "id": f.get("id", ""),
                "title": f.get("title", ""),
                "cascades_to": f.get("cascades_to", []),
                "resources": f.get("related_resources", []),
            })
            if f.get("cascades_to"):
                out["cascade_graph"].append({"from": f["id"], "to": f["cascades_to"]})

        for s in content.get("symptoms", []):
            out["symptoms"].append({"id": s.get("id", ""), "title": s.get("title", "")})

        for g in content.get("investigation_gaps", []):
            out["gaps"].append(g.get("title", ""))

        out["resources"] = sorted(all_resources)
    except Exception:
        pass
    return out


# --- Scoring ---

def score_rca(rca_text, ground_truth):
    if not rca_text:
        return {"match": False, "snippet": "no_rca_returned"}
    gt_keywords = ground_truth.replace("_", " ").split()
    rca_lower = rca_text.lower()
    matched = any(kw in rca_lower for kw in gt_keywords)
    snippet = next((l.strip() for l in rca_text.split("\n") if l.strip() and not l.startswith("#")), rca_text[:100])
    return {"match": matched, "snippet": snippet[:120]}


OPUS_PROMPT = """You are an expert SRE evaluating whether an AI DevOps agent correctly identified the root cause.

INJECTED FAULT: {description} (ground truth: {ground_truth})

AGENT RCA:
{agent_rca}

Did the agent identify the correct ROOT CAUSE (not just symptoms)?
If it traced the cause through CloudTrail/FIS API calls, that counts as valid.
Score: "yes" = correct cause, "partially" = right symptoms wrong cause, "no" = missed entirely.
Respond JSON only: {{"score": "yes|partially|no", "reasoning": "one sentence"}}"""


def score_with_opus(result):
    """Call Bedrock Opus to evaluate RCA quality."""
    rca = result.get("devops_agent_rca", "")
    if not rca:
        return {"score": "no", "reasoning": "No RCA returned by agent"}
    try:
        body = json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 200,
            "messages": [{"role": "user", "content": OPUS_PROMPT.format(
                description=result.get("description", ""),
                ground_truth=result.get("ground_truth", ""),
                agent_rca=rca[:3000],
            )}],
        })
        resp = bedrock.invoke_model(modelId="us.anthropic.claude-sonnet-4-6", body=body)
        text = json.loads(resp["body"].read())["content"][0]["text"]
        return json.loads(text)
    except Exception as e:
        return {"score": "error", "reasoning": str(e)[:100]}


# --- Main Loop ---

def run_experiment(exp, template_id, config, endpoint_id, queue_url, agent_space_id, agent_region, bucket, request_miti=False, failover=False):
    result = {
        "experiment": exp["id"],
        "name": exp["name"],
        "description": exp["description"],
        "ground_truth": exp["ground_truth"],
        "chaos_kind": exp["chaos_kind"],
        # Timeline
        "ts_experiment_started": None,
        "ts_agent_triggered": None,
        "ts_rca_completed": None,
        "ts_result_written": None,
        # FIS
        "fis_experiment_id": None,
        "fis_status": None,
        # Alarm
        "alarm_fired": False,
        # Agent
        "incident_id": None,
        "active_region": None,
        "webhook_status": None,
        "webhook_response": None,
        "task_id": None,
        "execution_id": None,
        "investigation_status": None,
        "devops_agent_rca": "",
        # Structured RCA
        "affected_resources": [],
        "cascade_graph": [],
        "findings": [],
        "symptoms": [],
        # Scoring
        "agent_match": False,
        "agent_rca_snippet": "",
        "opus_score": None,
        "opus_reasoning": None,
        # Mitigation
        "mitigation_status": None,
        "mitigation_action": None,
        "mitigation_reasoning": None,
        # Errors
        "errors": [],
    }

    print(f"\n{'='*60}")
    print(f"  {now_iso()} | START: {exp['name']} ({exp['id']})")
    print(f"  Ground truth: {exp['ground_truth']}")
    print(f"{'='*60}")

    # 1. Start FIS
    try:
        fis_id = start_experiment(template_id)
        result["fis_experiment_id"] = fis_id
        result["ts_experiment_started"] = now_iso()
        print(f"  {now_iso()} | [FIS] Experiment {fis_id} started")
    except Exception as e:
        result["errors"].append({"phase": "fis_start", "error": str(e), "ts": now_iso()})
        print(f"  {now_iso()} | [FIS] ERROR: {e}")
        return result

    # 2. Wait for fault to take effect
    print(f"  {now_iso()} | [WAIT] 15s for fault injection...")
    time.sleep(15)

    # 3. Check alarm (informational)
    try:
        resp = cw.describe_alarms(AlarmNames=[exp["expected_alarm"]])
        for a in resp.get("MetricAlarms", []):
            if a["StateValue"] == "ALARM":
                result["alarm_fired"] = True
                print(f"  {now_iso()} | [CW] ✓ Alarm '{exp['expected_alarm']}' FIRING")
        if not result["alarm_fired"]:
            print(f"  {now_iso()} | [CW] Alarm not firing (fast recovery or metric lag)")
    except Exception as e:
        result["errors"].append({"phase": "alarm_check", "error": str(e), "ts": now_iso()})

    # 4. Trigger DevOps Agent (via Global Endpoint)
    trigger_ts = time.time()
    try:
        inc_id = trigger_investigation(endpoint_id, exp, failover=failover)
        result["incident_id"] = inc_id
        result["ts_agent_triggered"] = now_iso()
        result["active_region"] = agent_region
        target_label = "secondary (direct)" if failover else "Global Endpoint"
        print(f"  {now_iso()} | [AGENT] PutEvents → {target_label}")
        print(f"  {now_iso()} | [AGENT] Incident ID: {inc_id}")
        # Wait briefly for forwarder to write routing decision to DynamoDB
        time.sleep(5)
        try:
            ddb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_DEFAULT_REGION", "us-west-2"))
            tbl = ddb.Table("fis-chaos-investigations")
            item = tbl.get_item(Key={"incident_id": inc_id}).get("Item", {})
            routed = item.get("routed_to", "pending")
            print(f"  {now_iso()} | [AGENT] Routed to: {routed}")
        except Exception:
            pass
    except Exception as e:
        result["errors"].append({"phase": "webhook", "error": str(e), "traceback": traceback.format_exc(), "ts": now_iso()})
        print(f"  {now_iso()} | [AGENT] Webhook ERROR: {e}")
        return result

    # 5. Wait for investigation completion via SQS
    try:
        task_id, exec_id, inv_status, summary_id, active_space, active_region = wait_for_investigation_ddb(inc_id)
        if active_space:
            agent_space_id = active_space
        if active_region:
            agent_region = active_region
        result["task_id"] = task_id
        result["execution_id"] = exec_id
        result["investigation_status"] = inv_status
        result["active_region"] = agent_region
        if inv_status and "COMPLETED" in inv_status:
            result["ts_rca_completed"] = now_iso()
            console_url = f"https://{agent_region}.console.aws.amazon.com/devops-agent/home?region={agent_region}#/spaces/{agent_space_id}/investigations/{task_id}"
            print(f"  {now_iso()} | [AGENT] ✓ Investigation {inv_status}")
            print(f"  {now_iso()} | [AGENT] Task ID: {task_id}")
            print(f"  {now_iso()} | [AGENT] Execution ID: {exec_id}")
            print(f"  {now_iso()} | [AGENT] Space: {agent_space_id} ({agent_region})")
            print(f"  {now_iso()} | [AGENT] Console: {console_url}")
            result["console_url"] = console_url
        elif inv_status == "POLL_TIMEOUT":
            result["errors"].append({"phase": "investigation", "error": "No investigation completed (EventBridge + API fallback)", "ts": now_iso()})
            print(f"  {now_iso()} | [AGENT] ✗ No completed investigation found")
        else:
            result["errors"].append({"phase": "investigation", "error": f"Investigation {inv_status}", "task_id": task_id, "ts": now_iso()})
            print(f"  {now_iso()} | [AGENT] ✗ Investigation {inv_status}")
    except Exception as e:
        result["errors"].append({"phase": "investigation", "error": str(e), "traceback": traceback.format_exc(), "ts": now_iso()})
        print(f"  {now_iso()} | [AGENT] ERROR: {e}")

    # 6. Retrieve RCA
    if result["execution_id"]:
        try:
            rca = get_rca_summary(agent_space_id, result["execution_id"], agent_region)
            result["devops_agent_rca"] = rca
            if rca:
                print(f"  {now_iso()} | [RCA] Retrieved ({len(rca)} chars)")
            else:
                result["errors"].append({"phase": "rca_fetch", "error": "Empty RCA returned", "ts": now_iso()})
                print(f"  {now_iso()} | [RCA] Empty — no summary record found")
        except Exception as e:
            result["errors"].append({"phase": "rca_fetch", "error": str(e), "traceback": traceback.format_exc(), "ts": now_iso()})
            print(f"  {now_iso()} | [RCA] ERROR: {e}")

        # 6b. Fetch structured data (resources, cascade graph)
        try:
            structured = get_structured_rca(agent_space_id, result["execution_id"], agent_region)
            result["affected_resources"] = structured["resources"]
            result["cascade_graph"] = structured["cascade_graph"]
            result["findings"] = structured["findings"]
            result["symptoms"] = structured["symptoms"]
            if structured["resources"]:
                print(f"  {now_iso()} | [RCA] Affected resources: {', '.join(structured['resources'])}")
            if structured["cascade_graph"]:
                print(f"  {now_iso()} | [RCA] Cascade chain: {len(structured['cascade_graph'])} links")
        except Exception:
            pass

    # 7. Wait for FIS to finish
    try:
        result["fis_status"] = wait_for_experiment(result["fis_experiment_id"])
    except Exception as e:
        result["errors"].append({"phase": "fis_wait", "error": str(e), "ts": now_iso()})

    # 7b. Mitigation
    if result["task_id"] and result["investigation_status"] and "COMPLETED" in result["investigation_status"]:
        # Only poll for mitigations when explicitly requested
        miti_status, miti_exec_id, miti_summary_id = "", "", ""
        if request_miti:
            active_queue = next((q for q in (queue_url if isinstance(queue_url, list) else [queue_url]) if agent_region in q), queue_url[0] if isinstance(queue_url, list) else queue_url) if queue_url else ""
            request_mitigation(agent_space_id, agent_region, result["task_id"])
            if active_queue:
                miti_status, miti_exec_id, miti_summary_id = wait_for_mitigation(active_queue, agent_space_id, result["task_id"])

        # API fallback: check executions directly if SQS didn't deliver
        if not miti_exec_id and request_miti:
            try:
                devops_client = get_devops_client(agent_region)
                execs = devops_client.list_executions(agentSpaceId=agent_space_id, taskId=result["task_id"])
                for ex in execs.get("executions", []):
                    if ex.get("agentSubTask") == "mitigation" and ex["executionStatus"] in ("COMPLETED", "STOPPED"):
                        miti_status = ex["executionStatus"]
                        miti_exec_id = ex["executionId"]
                        print(f"  [API] Found mitigation: {miti_exec_id} status={miti_status}")
                        break
            except Exception:
                pass

        # Fetch mitigation content
        if miti_exec_id:
            result["mitigation_status"] = miti_status
            try:
                devops_client = get_devops_client(agent_region)
                resp = devops_client.list_journal_records(
                    agentSpaceId=agent_space_id,
                    executionId=miti_exec_id,
                    recordType="mitigation_summary_md",
                    limit=1,
                )
                for rec in resp.get("records", []):
                    content = str(rec.get("content", ""))
                    result["mitigation_full"] = content
                    result["mitigation_action"] = content[:500]
                    for line in content.split("\n"):
                        if line.startswith("## Action"):
                            idx = content.index(line) + len(line) + 1
                            result["mitigation_action"] = content[idx:].split("\n")[0].strip()[:200]
                        if line.startswith("## Reasoning"):
                            idx = content.index(line) + len(line) + 1
                            result["mitigation_reasoning"] = content[idx:].split("\n")[0].strip()[:200]
                print(f"  {now_iso()} | [MITIGATE] ✓ {result.get('mitigation_action','')[:80]}")
            except Exception:
                pass
        else:
            if request_miti:
                print(f"  {now_iso()} | [MITIGATE] No mitigation found")

    # 8. Score — keyword match
    score = score_rca(result["devops_agent_rca"], result["ground_truth"])
    result["agent_match"] = score["match"]
    result["agent_rca_snippet"] = score["snippet"]

    # 9. Score — Opus quality assessment
    if result["devops_agent_rca"]:
        print(f"  {now_iso()} | [OPUS] Scoring RCA quality...")
        opus = score_with_opus(result)
        result["opus_score"] = opus.get("score")
        result["opus_reasoning"] = opus.get("reasoning")
        print(f"  {now_iso()} | [OPUS] {opus.get('score', '?')}: {opus.get('reasoning', '')[:80]}")

    return result


def print_scorecard(results):
    print(f"\n{'='*80}")
    print("  SCORECARD")
    print(f"{'='*80}")
    total = len(results)
    investigated = sum(1 for r in results if r["investigation_status"] and "COMPLETED" in r["investigation_status"])
    matches = sum(1 for r in results if r["agent_match"])
    errored = sum(1 for r in results if r["errors"])
    print(f"  Experiments run:       {total}")
    print(f"  Investigations done:   {investigated}/{total}")
    print(f"  Agent correct RCA:     {matches}/{investigated}" if investigated else "  Agent correct RCA:     N/A")
    if investigated:
        print(f"  Accuracy:              {matches/investigated*100:.0f}%")
    print(f"  Errors:                {errored}")

    # Summary table
    print(f"\n{'='*80}")
    print("  SUMMARY TABLE")
    print(f"{'='*80}")
    print(f"  {'#':<3} {'Experiment':<18} {'FIS':<10} {'Investigation':<22} {'Match':<6} {'Opus':<8} {'Mitigation':<12} {'Agent Found':<45}")
    print(f"  {'─'*3} {'─'*18} {'─'*10} {'─'*22} {'─'*6} {'─'*8} {'─'*12} {'─'*45}")
    for i, r in enumerate(results, 1):
        fis_st = "✅ done" if r["fis_status"] == "completed" else f"❌ {r['fis_status'] or '?'}"
        inv_st = r.get("investigation_status") or "—"
        if "COMPLETED" in inv_st:
            inv_st = f"✅ {inv_st}"
        elif inv_st == "POLL_TIMEOUT":
            inv_st = "⚠ timeout"
        else:
            inv_st = f"❌ {inv_st}"
        match = "✓" if r["agent_match"] else ("—" if not r.get("devops_agent_rca") else "✗")
        opus = r.get("opus_score") or "—"
        miti = r.get("mitigation_status") or "none"
        if miti == "STOPPED":
            miti = "✅ ready"
        elif miti == "IN_PROGRESS":
            miti = "⏳ pending"
        elif miti == "none":
            miti = "— self-healed"
        agent_found = _extract_agent_reasoning(r.get("devops_agent_rca", ""))
        print(f"  {i:<3} {r['name']:<18} {fis_st:<10} {inv_st:<22} {match:<6} {opus:<8} {miti:<12} {agent_found[:45]}")

    # Detailed comparison
    print(f"\n{'='*80}")
    print("  EXPERIMENT vs AGENT RCA COMPARISON")
    print(f"{'='*80}")
    for r in results:
        icon = "✓" if r["agent_match"] else ("⚠" if r["errors"] else "✗")
        if not r["investigation_status"]:
            icon = "○"

        rca = r.get("devops_agent_rca", "")
        symptoms = _extract_section(rca, "Symptoms")
        findings = _extract_section(rca, "Findings")
        root_cause = _extract_section(rca, "Root Cause")
        gaps = _extract_section(rca, "Other Gaps")

        print(f"\n  {icon} {r['name']}")
        print(f"  {'─'*76}")
        print(f"  INJECTED FAULT (what FIS did):")
        print(f"    Experiment:    {r['name']} ({r['chaos_kind']})")
        print(f"    Description:   {r['description']}")
        print(f"    Ground truth:  {r['ground_truth']}")
        print(f"    FIS status:    {r['fis_status']}")
        print(f"    Task ID:       {r.get('task_id', 'N/A')}")
        print(f"  AGENT DIAGNOSIS (what DevOps Agent found):")
        print(f"    Symptoms:      {symptoms}")
        print(f"    Root cause:    {findings or root_cause}")
        print(f"    Reasoning:     {_extract_agent_reasoning(rca)}")
        print(f"    Status:        {'Resolved (transient)' if 'recover' in rca.lower() or 'resolved' in rca.lower() or 'self-heal' in rca.lower() else 'Ongoing or unknown'}")
        print(f"    Blast radius:  {_extract_blast_radius(rca, r)}")
        if r.get("cascade_graph"):
            print(f"    Cascade:")
            for link in r["cascade_graph"]:
                print(f"      {link['from']} → {', '.join(link['to'])}")
        if r.get("opus_score"):
            print(f"    Opus verdict:  {r['opus_score']} — {r.get('opus_reasoning', '')[:80]}")
        if r.get("mitigation_action"):
            print(f"    Mitigation:    {r['mitigation_action'][:100]}")
        elif r.get("mitigation_status"):
            print(f"    Mitigation:    {r['mitigation_status']}")
        else:
            print(f"    Mitigation:    none (issue self-resolved)")
        if gaps:
            print(f"    Gaps:          {gaps}")
        if r["errors"]:
            print(f"    ERRORS:        {[e['error'] for e in r['errors']]}")

    # Timeline
    print(f"\n{'='*80}")
    print("  TIMELINE")
    print(f"{'='*80}")
    print(f"  {'Experiment':<20s} {'FIS Started':<28s} {'Agent Triggered':<28s} {'RCA Completed':<28s} {'Written':<28s}")
    for r in results:
        print(f"  {r['name']:<20s} {r['ts_experiment_started'] or '-':<28s} {r['ts_agent_triggered'] or '-':<28s} {r['ts_rca_completed'] or '-':<28s} {r['ts_result_written'] or '-':<28s}")
    print()


def _extract_agent_reasoning(rca):
    """Extract the key reasoning — what evidence the agent used to reach its conclusion."""
    if not rca:
        return "No RCA returned"
    import re
    # Look for root cause or findings section and get the description
    lines = rca.split("\n")
    for i, line in enumerate(lines):
        if line.startswith("### ") and ("cause" in line.lower() or "root" in line.lower()):
            # Get the **Description:** line that follows
            for j in range(i+1, min(i+5, len(lines))):
                if lines[j].startswith("**Description:**"):
                    desc = lines[j].replace("**Description:**", "").strip()
                    # Truncate to first sentence
                    first_sentence = re.split(r'(?<=[.!])\s', desc)[0]
                    return first_sentence[:120]
            # Fallback to heading text
            return re.sub(r'^#+\s*', '', line).strip()[:120]
    # Fallback: first symptom description
    for i, line in enumerate(lines):
        if line.startswith("### ") and "symptom" not in line.lower():
            return re.sub(r'^#+\s*', '', line).strip()[:120]
    return rca.split("\n")[0][:120]

    # Timeline
    print(f"\n{'='*80}")
    print("  TIMELINE")
    print(f"{'='*80}")
    print(f"  {'Experiment':<20s} {'FIS Started':<28s} {'Agent Triggered':<28s} {'RCA Completed':<28s} {'Written':<28s}")
    for r in results:
        print(f"  {r['name']:<20s} {r['ts_experiment_started'] or '-':<28s} {r['ts_agent_triggered'] or '-':<28s} {r['ts_rca_completed'] or '-':<28s} {r['ts_result_written'] or '-':<28s}")
    print()


def _extract_section(rca, heading):
    """Extract first subsection heading under a top-level section."""
    import re
    lines = rca.split("\n")
    in_section = False
    for line in lines:
        # Match ## Symptoms, ## Findings, ## Root Cause, ## Other Gaps
        if line.startswith("## ") and heading.lower() in line.lower():
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break  # next top-level section
        if in_section and line.startswith("### "):
            return re.sub(r'^#+\s*', '', line).strip()[:150]
        if in_section and line.startswith("**Description:**"):
            return line.replace("**Description:**", "").strip()[:150]
    # Fallback: look for "Root Cause:" or "Cause:" anywhere in headings
    if heading.lower() in ("findings", "root cause"):
        for line in lines:
            if line.startswith("### ") and ("cause" in line.lower() or "root" in line.lower()):
                return re.sub(r'^#+\s*', '', line).strip()[:150]
    return "N/A"


def _extract_blast_radius(rca, result=None):
    """Get blast radius from structured data, fall back to keyword scan."""
    if result and result.get("affected_resources"):
        resources = result["affected_resources"]
        return f"{len(resources)} resource(s): {', '.join(resources)}"
    # Fallback: keyword scan
    if not rca:
        return "Unknown"
    rca_lower = rca.lower()
    components = [s for s in ["ui", "catalog", "checkout", "orders", "carts", "assets"] if s in rca_lower]
    if not components:
        return "Unknown"
    return f"{'Single' if len(components) == 1 else 'Multiple'} service(s) ({', '.join(components)})"


def cleanup_chaos_crds():
    """Delete all stale Chaos Mesh CRDs across namespaces."""
    import subprocess
    kinds = ["podchaos", "networkchaos", "httpchaos", "stresschaos", "iochaos", "dnschaos"]
    deleted = 0
    for kind in kinds:
        result = subprocess.run(
            ["kubectl", "get", kind, "-A", "-o", "jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}\n{end}"],
            capture_output=True, text=True
        )
        for line in result.stdout.strip().split("\n"):
            if not line or "/" not in line:
                continue
            ns, name = line.split("/", 1)
            print(f"  [CLEAN] Deleting {kind}/{name} in {ns}")
            # Try normal delete first
            dr = subprocess.run(["kubectl", "delete", kind, name, "-n", ns, "--timeout=10s"], capture_output=True, text=True)
            if dr.returncode != 0:
                # Force remove finalizers
                subprocess.run(
                    ["kubectl", "patch", kind, name, "-n", ns, "-p", '{"metadata":{"finalizers":[]}}', "--type=merge"],
                    capture_output=True, text=True
                )
                subprocess.run(["kubectl", "delete", kind, name, "-n", ns, "--force", "--grace-period=0"], capture_output=True, text=True)
            deleted += 1
    if deleted:
        print(f"  [CLEAN] Removed {deleted} stale CRD(s)")
    else:
        print(f"  [CLEAN] No stale Chaos Mesh CRDs found")


def main():
    p = argparse.ArgumentParser(description="FIS ↔ DevOps Agent Chaos Orchestrator")
    p.add_argument("--config", default="experiments.json")
    p.add_argument("--templates", required=True, help="JSON: {experiment_id: FIS_template_id}")
    # Global Endpoint
    p.add_argument("--endpoint-id", default=os.environ.get("ENDPOINT_ID", ""), help="EventBridge Global Endpoint ID")
    # Agent space (for SQS polling + API calls)
    p.add_argument("--agent-space-id", required=True, help="DevOps Agent space ID")
    p.add_argument("--queue-url", required=False, default="", help="SQS queue URL for agent events (optional, DynamoDB polling used if omitted)")
    p.add_argument("--agent-region", default=os.environ.get("AGENT_REGION", "us-east-1"), help="Agent region")
    # Other
    p.add_argument("--bucket", required=True, help="S3 bucket for results")
    p.add_argument("--mitigation", action="store_true", help="Request mitigation via ACP chat after investigation completes")
    p.add_argument("--failover", action="store_true", help="Send to secondary agent directly (bypass Global Endpoint routing)")
    p.add_argument("--random", action="store_true")
    p.add_argument("--limit", type=int, help="Run only first N experiments")
    p.add_argument("--experiment", help="Run single experiment by ID")
    p.add_argument("--fetch-rca", help="Fetch RCA for a previous result file (S3 key or local path)")
    p.add_argument("--request-mitigation", help="Request mitigation for an existing task ID (skips investigation)")
    p.add_argument("--clean", action="store_true", help="Delete stale Chaos Mesh CRDs before running experiments")
    args = p.parse_args()

    # --failover: sends events directly to secondary bus (bypasses Global Endpoint routing)

    # --clean: remove stale Chaos Mesh CRDs before running
    if args.clean:
        cleanup_chaos_crds()

    # Request-mitigation mode: trigger mitigation on an existing task
    if args.request_mitigation:
        task_id = args.request_mitigation
        agent_space_id = args.agent_space_id
        agent_region = args.agent_region
        # If --failover, resolve secondary space/region from Secrets Manager
        if args.failover:
            sm = boto3.client("secretsmanager", region_name=os.environ.get("AWS_DEFAULT_REGION", "us-west-2"))
            config = json.loads(sm.get_secret_value(SecretId="fis-chaos/webhook-proxy")["SecretString"])
            agent_space_id = config.get("secondary_agent_space_id", agent_space_id)
            agent_region = config.get("secondary_region", agent_region)
        print(f"Requesting mitigation for task {task_id} in {agent_region}...")
        response = request_mitigation(agent_space_id, agent_region, task_id)
        if response:
            print(f"\nAgent response ({len(response)} chars):\n{response[:1000]}")
        return

    # Fetch-RCA mode: read a previous result, look up the investigation, get RCA
    if args.fetch_rca:
        path = args.fetch_rca
        if path.startswith("s3://"):
            parts = path.replace("s3://", "").split("/", 1)
            obj = s3.get_object(Bucket=parts[0], Key=parts[1])
            result = json.loads(obj["Body"].read())
        else:
            with open(path) as f:
                result = json.load(f)
        print(f"Fetching RCA for: {result['name']} (incident={result.get('incident_id','?')})")
        # Try to find the task
        fetch_region = result.get("active_region", args.agent_region)
        devops_client = get_devops_client(fetch_region)
        tasks = devops_client.list_backlog_tasks(agentSpaceId=args.agent_space_id, limit=20)
        for t in tasks.get("tasks", []):
            title = t.get("title", "")
            inc_id = result.get("incident_id", "")
            if inc_id and inc_id in title:
                print(f"Found task: {t['taskId']} status={t['status']}")
                exec_id = t.get("executionId", "")
                if not exec_id and t.get("primaryTaskId"):
                    execs = devops_client.list_executions(agentSpaceId=args.agent_space_id, taskId=t["primaryTaskId"])
                    for ex in execs.get("executions", []):
                        if ex["executionStatus"] == "COMPLETED":
                            exec_id = ex["executionId"]
                if exec_id:
                    rca = get_rca_summary(args.agent_space_id, exec_id, fetch_region)
                    print(f"RCA ({len(rca)} chars):\n{rca[:500]}")
                    result["devops_agent_rca"] = rca
                    result["execution_id"] = exec_id
                    result["task_id"] = t["taskId"]
                    result["ts_rca_completed"] = now_iso()
                    # Re-upload to S3
                    key = f"experiments/{result['experiment']}/{result['ts_experiment_started']}.json"
                    result["ts_result_written"] = now_iso()
                    s3.put_object(Bucket=args.bucket, Key=key, Body=json.dumps(result, indent=2), ContentType="application/json")
                    print(f"Updated → s3://{args.bucket}/{key}")
                else:
                    print(f"No execution ID found for task {t['taskId']}")
                break
        else:
            print("No matching task found in agent space")
        return

    config = load_json(args.config)
    templates = load_json(args.templates)
    experiments = config["experiments"]

    if args.experiment:
        experiments = [e for e in experiments if e["id"] == args.experiment]
        if not experiments:
            sys.exit(f"Experiment '{args.experiment}' not found")

    if args.random:
        random.shuffle(experiments)

    if args.limit:
        experiments = experiments[:args.limit]

    results = []
    # Build list of queue URLs to poll (primary + secondary)
    queue_urls = [args.queue_url]
    try:
        sm = boto3.client("secretsmanager", region_name=os.environ.get("AWS_DEFAULT_REGION", "us-west-2"))
        config_secret = json.loads(sm.get_secret_value(SecretId="fis-chaos/webhook-proxy")["SecretString"])
        secondary_queue = config_secret.get("secondary_queue_url", "")
        if secondary_queue and secondary_queue != args.queue_url:
            queue_urls.append(secondary_queue)
    except Exception:
        pass
    for exp in experiments:
        tid = templates.get(exp["id"])
        if not tid:
            print(f"Skipping {exp['id']}: no template ID")
            continue

        result = run_experiment(exp, tid, config, args.endpoint_id,
                               queue_urls, args.agent_space_id, args.agent_region,
                               args.bucket, args.mitigation, args.failover)

        # Upload to S3 — keyed by incident_id for direct lookup
        incident = result.get("incident_id") or result.get("ts_experiment_started") or now_iso()
        key = f"experiments/{result['experiment']}/{incident}.json"
        result["ts_result_written"] = now_iso()
        s3.put_object(Bucket=args.bucket, Key=key, Body=json.dumps(result, indent=2), ContentType="application/json")
        print(f"  {now_iso()} | [S3] → s3://{args.bucket}/{key}")

        results.append(result)
        if exp != experiments[-1]:
            cd = config.get("cooldown_seconds", 120)
            print(f"  Cooldown {cd}s...")
            time.sleep(cd)

    print_scorecard(results)
    os.makedirs("results", exist_ok=True)
    out = f"results/results_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"Results → {out}")


if __name__ == "__main__":
    main()

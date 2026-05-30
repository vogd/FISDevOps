"""
RCA Writer Lambda — triggered by EventBridge on Investigation/Mitigation Completed.
Fetches RCA and mitigation from DevOps Agent API, writes to S3.
Deployed in BOTH regions so each agent space's completions get persisted.
"""
import json
import os
import re
import boto3
import boto3.dynamodb.conditions
from datetime import datetime, timezone

s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET"]
TABLE_NAME = os.environ.get("TABLE_NAME", "fis-chaos-investigations")
REGION = os.environ.get("AWS_REGION", "us-east-1")

_devops_client = None

def get_devops_client():
    global _devops_client
    if _devops_client is None:
        _devops_client = boto3.client("devops-agent", region_name=REGION)
    return _devops_client


def _resolve_incident_id(table, task_id):
    """Resolve incident_id from task_id via GSI."""
    resp = table.query(
        IndexName="task_id-index",
        KeyConditionExpression=boto3.dynamodb.conditions.Key("task_id").eq(task_id),
        Limit=1,
    )
    items = resp.get("Items", [])
    return items[0]["incident_id"] if items else ""


def handler(event, context):
    detail_type = event.get("detail-type", "")
    detail = event.get("detail", {})
    meta = detail.get("metadata", {})
    data = detail.get("data", {})

    agent_space_id = meta.get("agent_space_id")
    task_id = meta.get("task_id")
    execution_id = meta.get("execution_id")
    summary_record_id = data.get("summary_record_id", "")

    if not agent_space_id or not execution_id:
        return {"status": "skipped", "reason": "missing metadata"}

    result = {
        "detail_type": detail_type,
        "agent_space_id": agent_space_id,
        "task_id": task_id,
        "execution_id": execution_id,
        "region": REGION,
        "status": data.get("status"),
        "priority": data.get("priority"),
        "created_at": data.get("created_at"),
        "updated_at": data.get("updated_at"),
        "written_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    # Fetch RCA or mitigation content
    if "Investigation" in detail_type:
        record_type = "investigation_summary_md"
        prefix = "investigations"
    else:
        record_type = "mitigation_summary_md"
        prefix = "mitigations"

    try:
        resp = get_devops_client().list_journal_records(
            agentSpaceId=agent_space_id,
            executionId=execution_id,
            recordType=record_type,
            limit=1,
        )
        records = resp.get("records", [])
        if records:
            content = records[0].get("content", "")
            result["content"] = content if isinstance(content, str) else json.dumps(content)
    except Exception as e:
        result["error"] = str(e)

    # Also fetch structured summary for investigations
    if "Investigation" in detail_type:
        try:
            resp = get_devops_client().list_journal_records(
                agentSpaceId=agent_space_id,
                executionId=execution_id,
                recordType="investigation_summary",
                limit=1,
            )
            records = resp.get("records", [])
            if records:
                content = records[0].get("content", {})
                if isinstance(content, str):
                    content = json.loads(content)
                result["findings"] = content.get("findings", [])
                result["symptoms"] = content.get("symptoms", [])
                result["investigation_gaps"] = content.get("investigation_gaps", [])

                # Write affected_resources + cascade_graph to DynamoDB for Neptune feeder
                affected = []
                cascade = []
                for f in result["findings"]:
                    affected.extend(f.get("related_resources", []))
                    if f.get("cascades_to"):
                        cascade.append({"from": f.get("id", ""), "to": f["cascades_to"]})

                if affected or cascade:
                    try:
                        ddb = boto3.resource("dynamodb", region_name=REGION)
                        table = ddb.Table(TABLE_NAME)
                        incident_id = _resolve_incident_id(table, task_id) if task_id else ""
                        if incident_id:
                            # Extract ARNs and K8s resource paths from RCA content
                            rca_text = result.get("content", "")
                            arns = list(set(re.findall(
                                r'arn:aws:[a-zA-Z0-9\-]+:[a-z0-9\-]*:\d*:[a-zA-Z0-9:/_\-.]+', rca_text
                            )))
                            k8s_paths = list(set(re.findall(
                                r'(?:^|\s)([\w\-]+/(?:deployment|pod|statefulset|daemonset|service|configmap)/[\w\-.]+)',
                                rca_text
                            )))

                            update_expr = "SET affected_resources = :ar, cascade_graph = :cg"
                            expr_values = {":ar": affected, ":cg": cascade}

                            if arns or k8s_paths:
                                update_expr += ", resource_arns = :arns"
                                expr_values[":arns"] = arns + k8s_paths

                            table.update_item(
                                Key={"incident_id": incident_id},
                                UpdateExpression=update_expr,
                                ExpressionAttributeValues=expr_values,
                            )
                    except Exception as e:
                        print(f"DDB enrichment error (non-fatal): {e}")
        except Exception:
            pass

    # Write to S3
    key = f"{prefix}/{task_id}/{execution_id}.json"
    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=json.dumps(result, indent=2),
        ContentType="application/json",
    )

    # Write graph node data for graph_builder Lambda
    if "Investigation" in detail_type and "Completed" in detail_type:
        incident_id = ""
        if task_id:
            try:
                ddb = boto3.resource("dynamodb", region_name=REGION)
                table = ddb.Table(TABLE_NAME)
                incident_id = _resolve_incident_id(table, task_id)
            except Exception as e:
                print(f"Graph: resolve_incident_id failed: {e}")
        if incident_id:
            graph_node = {
                "incident_id": incident_id,
                "status": data.get("status", "COMPLETED"),
                "ts": data.get("created_at", result.get("written_at", "")),
                "affected_resources": [r for f in result.get("findings", []) for r in f.get("related_resources", [])],
                "cascade_graph": [{"from": f.get("id", ""), "to": f["cascades_to"]} for f in result.get("findings", []) if f.get("cascades_to")],
                "resource_arns": list(set(re.findall(r'arn:aws:[a-zA-Z0-9\-]+:[a-z0-9\-]*:\d*:[a-zA-Z0-9:/_\-.]+', result.get("content", "")))),
            }
            s3.put_object(
                Bucket=BUCKET,
                Key=f"graph/{incident_id}.json",
                Body=json.dumps(graph_node),
                ContentType="application/json",
            )
            print(f"Graph: written graph/{incident_id}.json")

    print(f"Written: s3://{BUCKET}/{key} ({detail_type})")
    return {"status": "written", "key": key}

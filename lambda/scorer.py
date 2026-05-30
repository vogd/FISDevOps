"""
Lambda scorer: reads experiment results from S3, calls Opus to judge
whether DevOps Agent RCA matches the injected fault, writes scorecard back.
"""
import json
import os
import boto3

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime", region_name=os.environ.get("AWS_REGION", "us-west-2"))
BUCKET = os.environ["BUCKET"]
MODEL_ID = os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-4-6")

PROMPT = """You are an expert SRE evaluating whether an AI DevOps agent correctly identified the root cause of an incident.

INJECTED FAULT (ground truth):
- Experiment: {experiment_name}
- Fault type: {ground_truth}
- Description: {description}

DEVOPS AGENT RCA:
{agent_rca}

Evaluate whether the agent correctly identified the ROOT CAUSE — not just symptoms.
A symptom is what happened as a result (e.g., liveness probe failed, pod restarted).
A root cause is what initiated the failure (e.g., container was killed, CPU exhausted, network partitioned).

Example of WRONG diagnosis:
- Ground truth: container was killed
- Agent says: "liveness probe timed out" → This is a SYMPTOM of the kill, not the cause. Score: no.

Example of CORRECT diagnosis:
- Ground truth: container was killed  
- Agent says: "container was terminated/killed, causing pod restart" → Correct cause. Score: yes.

Ignore whether the agent identified the injection tool (Chaos Mesh, FIS). Focus only on:
1. Did the agent identify the correct CAUSE category (not just downstream symptoms)?
2. Did the agent identify the correct affected component?
3. If the agent traced the cause through API calls (CloudTrail, FIS StartExperiment), that is a VALID finding path — score as "yes" if the fault category matches.

Failure categories:
- pod_failure: pod killed, terminated, force-deleted (NOT "liveness probe failed")
- container_failure: specific container killed/terminated (NOT "probe timeout")
- network_latency: injected delay on network path (NOT "slow response times" alone)
- network_packet_loss: injected packet drops (NOT "connection errors" alone)
- network_partition: network path severed between services
- cpu_pressure: CPU stress/exhaustion injected (NOT "high CPU observed" alone)
- memory_pressure: memory stress injected (NOT "high memory observed" alone)
- io_latency: disk I/O delay injected
- http_fault: HTTP errors injected at proxy level
- dns_failure: DNS resolution errors injected

Score:
- "yes" = agent identified the correct root cause category and affected component
- "partially" = agent identified correct symptoms but attributed wrong cause
- "no" = agent missed the failure or diagnosed completely wrong category

Respond in JSON only: {{"score": "yes|partially|no", "reasoning": "..."}}'"""


def score_one(result):
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 256,
        "messages": [{"role": "user", "content": PROMPT.format(
            experiment_name=result.get("name", ""),
            ground_truth=result.get("ground_truth", ""),
            description=result.get("description", ""),
            agent_rca=result.get("devops_agent_rca", "no RCA available"),
        )}],
    })
    resp = bedrock.invoke_model(modelId=MODEL_ID, body=body)
    text = json.loads(resp["body"].read())["content"][0]["text"]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"score": "error", "reasoning": text[:200]}


def handler(event, context):
    # List all experiment results
    prefix = "experiments/"
    objs = s3.list_objects_v2(Bucket=BUCKET, Prefix=prefix).get("Contents", [])

    results = []
    for obj in objs:
        data = json.loads(s3.get_object(Bucket=BUCKET, Key=obj["Key"])["Body"].read())
        verdict = score_one(data)
        data["opus_score"] = verdict["score"]
        data["opus_reasoning"] = verdict["reasoning"]
        results.append(data)

    # Build scorecard with ordered columns
    scored_results = []
    for data in results:
        scored_results.append({
            "experiment": data.get("experiment"),
            "name": data.get("name"),
            "fis_description": data.get("description"),
            "ground_truth": data.get("ground_truth"),
            "chaos_kind": data.get("chaos_kind"),
            "fis_status": data.get("fis_status"),
            "devops_agent_rca_snippet": data.get("agent_rca_snippet", ""),
            "devops_agent_rca_full": data.get("devops_agent_rca", ""),
            "opus_score": data.get("opus_score"),
            "opus_reasoning": data.get("opus_reasoning"),
            "ts_experiment_started": data.get("ts_experiment_started"),
            "ts_rca_completed": data.get("ts_rca_completed"),
            "errors": data.get("errors", []),
        })

    scorecard = {
        "total": len(scored_results),
        "correct": sum(1 for r in scored_results if r["opus_score"] == "yes"),
        "partial": sum(1 for r in scored_results if r["opus_score"] == "partially"),
        "wrong": sum(1 for r in scored_results if r["opus_score"] == "no"),
        "results": scored_results,
    }
    s3.put_object(
        Bucket=BUCKET,
        Key="scorecards/latest.json",
        Body=json.dumps(scorecard, indent=2),
        ContentType="application/json",
    )
    return scorecard

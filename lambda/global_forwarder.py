"""
Global Endpoint Forwarder — SQS-triggered Lambda that HMAC-signs and forwards to agent webhooks.

Reads ALL webhook endpoints from Secrets Manager dynamically.
Routes to least-loaded space. First endpoint = primary, rest = failover targets.
No hardcoded space IDs or webhook URLs in Lambda config.

Secret format (list of endpoints):
{
  "endpoints": [
    {"space_id": "...", "region": "eu-west-1", "webhook_url": "...", "webhook_secret": "..."},
    {"space_id": "...", "region": "eu-central-1", "webhook_url": "...", "webhook_secret": "..."}
  ]
}
"""
import base64
import hashlib
import hmac
import json
import os
import time
from datetime import datetime, timezone
from urllib import request, error

import boto3

secrets = boto3.client("secretsmanager")
dynamodb = boto3.resource("dynamodb")
_config_cache = None
_config_cache_ts = 0
CONFIG_TTL = 60


def get_endpoints():
    """Read endpoint list from Secrets Manager. Cached for 60s. Creates missing queues on first load."""
    global _config_cache, _config_cache_ts
    if _config_cache is None or (time.time() - _config_cache_ts) > CONFIG_TTL:
        resp = secrets.get_secret_value(SecretId=os.environ["SECRET_ID"])
        config = json.loads(resp["SecretString"])
        # Support both old format (flat keys) and new format (endpoints list)
        if "endpoints" in config:
            _config_cache = config["endpoints"]
        else:
            # Backwards compatible: convert old flat format to list
            _config_cache = []
            if config.get("primary_webhook_url"):
                _config_cache.append({
                    "space_id": config.get("primary_agent_space_id", ""),
                    "region": config.get("primary_region", ""),
                    "webhook_url": config["primary_webhook_url"],
                    "webhook_secret": config["primary_webhook_secret"],
                })
            if config.get("secondary_webhook_url"):
                _config_cache.append({
                    "space_id": config.get("secondary_agent_space_id", ""),
                    "region": config.get("secondary_region", ""),
                    "webhook_url": config["secondary_webhook_url"],
                    "webhook_secret": config["secondary_webhook_secret"],
                })

        # Cold start: ensure SQS queues exist for each endpoint
        updated = False
        for ep in _config_cache:
            if not ep.get("queue_url") and ep.get("region"):
                try:
                    sqs_client = boto3.client("sqs", region_name=ep["region"])
                    queue_name = "fis-chaos-agent-events"
                    resp_q = sqs_client.create_queue(
                        QueueName=queue_name,
                        Attributes={"MessageRetentionPeriod": "86400", "VisibilityTimeout": "60", "ReceiveMessageWaitTimeSeconds": "20"},
                    )
                    ep["queue_url"] = resp_q["QueueUrl"]
                    updated = True
                    print(f"Created queue {queue_name} in {ep['region']}: {ep['queue_url']}")
                except Exception as e:
                    print(f"Queue creation skipped for {ep['region']}: {e}")

        # Write back updated endpoints with queue_urls
        if updated:
            try:
                secrets.put_secret_value(
                    SecretId=os.environ["SECRET_ID"],
                    SecretString=json.dumps({"endpoints": _config_cache}),
                )
                print("Updated secret with queue URLs")
            except Exception as e:
                print(f"Secret update failed (non-fatal): {e}")

        _config_cache_ts = time.time()
    return _config_cache


MAX_CONCURRENT = int(os.environ.get("MAX_CONCURRENT_INVESTIGATIONS", "3"))


def get_space_load(table_name):
    """Get active investigation count per space from DynamoDB."""
    table = dynamodb.Table(table_name)
    resp = table.scan(
        FilterExpression="detail_type IN (:s1, :s2)",
        ExpressionAttributeValues={
            ":s1": "Investigation Created",
            ":s2": "Investigation In Progress",
        },
        ProjectionExpression="space_id",
    )
    counts = {}
    for item in resp.get("Items", []):
        sid = item.get("space_id", "")
        counts[sid] = counts.get(sid, 0) + 1
    return counts


def pick_endpoint(endpoints, table_name):
    """Pick least-loaded endpoint. First endpoint is preferred when loads are equal."""
    if not endpoints:
        raise RuntimeError("No endpoints configured in secret")
    if len(endpoints) == 1 or not table_name:
        return 0, endpoints[0]

    load = get_space_load(table_name)
    best_idx = 0
    best_load = load.get(endpoints[0]["space_id"], 0)

    for i, ep in enumerate(endpoints[1:], 1):
        ep_load = load.get(ep["space_id"], 0)
        if ep_load < best_load:
            best_idx = i
            best_load = ep_load

    parts = [f"{ep['region']}={load.get(ep['space_id'],0)}/{MAX_CONCURRENT}" for ep in endpoints]
    print(f"Routing: {' | '.join(parts)} -> [{best_idx}] {endpoints[best_idx]['region']}")
    return best_idx, endpoints[best_idx]


def sign_and_send(webhook_url, webhook_secret, payload_str):
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    sig_input = f"{timestamp}:{payload_str}"
    signature = base64.b64encode(
        hmac.new(webhook_secret.encode(), sig_input.encode(), hashlib.sha256).digest()
    ).decode()
    req = request.Request(
        webhook_url,
        data=payload_str.encode(),
        headers={
            "Content-Type": "application/json",
            "x-amzn-event-timestamp": timestamp,
            "x-amzn-event-signature": signature,
        },
        method="POST",
    )
    resp = request.urlopen(req, timeout=10)
    return resp.status, resp.read().decode()


def record_routing(payload_str, endpoint, table_name):
    """Write routing decision to DynamoDB."""
    if not table_name:
        return
    try:
        payload = json.loads(payload_str)
        incident_id = payload.get("incidentId", "")
        if not incident_id:
            return
        table = dynamodb.Table(table_name)
        table.update_item(
            Key={"incident_id": incident_id},
            UpdateExpression="SET routed_to = :r, space_id = :s, forwarded_at = :t",
            ExpressionAttributeValues={
                ":r": endpoint["region"],
                ":s": endpoint["space_id"],
                ":t": int(time.time()),
            },
        )
    except Exception as e:
        print(f"DDB write error (non-fatal): {e}")


def handler(event, context):
    endpoints = get_endpoints()
    table_name = os.environ.get("TABLE_NAME")
    failover_queue_url = os.environ.get("FAILOVER_QUEUE_URL", "")

    for record in event.get("Records", []):
        body = record["body"]
        is_forwarded = record.get("messageAttributes", {}).get("forwarded", {}).get("stringValue") == "true"

        # Extract payload from EventBridge envelope
        try:
            eb_event = json.loads(body)
            payload = json.dumps(eb_event.get("detail", eb_event))
            # Check for force_target hint
            detail = eb_event.get("detail", {})
            if isinstance(detail, str):
                detail = json.loads(detail)
            force_target = detail.get("force_target", "")
        except (json.JSONDecodeError, KeyError):
            payload = body
            force_target = ""

        # Try endpoints in order of load (least-loaded first), skip failures
        tried = set()
        success = False

        if force_target:
            # Force routing to specific region
            order = [ep for ep in endpoints if ep["region"] == force_target] + [ep for ep in endpoints if ep["region"] != force_target]
        else:
            _, best_ep = pick_endpoint(endpoints, table_name)
            order = [best_ep] + [ep for ep in endpoints if ep != best_ep]

        for ep in order:
            if ep["space_id"] in tried:
                continue
            tried.add(ep["space_id"])
            try:
                status, _ = sign_and_send(ep["webhook_url"], ep["webhook_secret"], payload)
                if status == 200:
                    record_routing(payload, ep, table_name)
                    print(f"OK: forwarded to {ep['region']} ({ep['space_id'][:8]})")
                    success = True
                    break
                else:
                    print(f"FAILED {ep['region']}: HTTP {status}")
            except Exception as e:
                print(f"FAILED {ep['region']}: {e}")

        if not success:
            if not is_forwarded and failover_queue_url:
                print("All endpoints failed — routing to failover queue")
                sqs = boto3.client("sqs", region_name=os.environ.get("FAILOVER_REGION", ""))
                sqs.send_message(
                    QueueUrl=failover_queue_url,
                    MessageBody=body,
                    MessageAttributes={"forwarded": {"DataType": "String", "StringValue": "true"}},
                )
            else:
                print("All endpoints failed (already forwarded) — DLQ")
                raise RuntimeError("All endpoints exhausted")

    return {"batchItemFailures": []}

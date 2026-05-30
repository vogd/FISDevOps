"""
Dispatcher Lambda — links task_id to incident_id and writes investigation status to DynamoDB.

On "Investigation Created": calls agent API to get task title, extracts incident_id, writes mapping.
On subsequent events: looks up incident_id from task_id mapping, updates status.
Orchestrator polls DynamoDB by incident_id only — no SQS consumption needed.
"""
import json
import os
import time

import boto3

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])


def get_devops_client(region):
    return boto3.client("devops-agent", region_name=region)


def resolve_incident_id(task_id, space_id, region):
    """Call agent API to get task title, extract incident_id from [incident_id] prefix."""
    import time
    for attempt in range(3):
        try:
            client = get_devops_client(region)
            next_token = None
            while True:
                kwargs = {"agentSpaceId": space_id, "limit": 100}
                if next_token:
                    kwargs["nextToken"] = next_token
                resp = client.list_backlog_tasks(**kwargs)
                for t in resp.get("tasks", []):
                    if t["taskId"] == task_id:
                        title = t.get("title", "")
                        if "[" in title and "]" in title:
                            return title.split("[")[1].split("]")[0]
                next_token = resp.get("nextToken")
                if not next_token:
                    break
        except Exception as e:
            print(f"resolve_incident_id error (attempt {attempt+1}): {e}")
        if attempt < 2:
            time.sleep(5)  # wait for eventual consistency
    return None


def get_incident_id_from_task(task_id):
    """Look up incident_id from DynamoDB using task_id index."""
    try:
        resp = table.query(
            IndexName="task_id-index",
            KeyConditionExpression=boto3.dynamodb.conditions.Key("task_id").eq(task_id),
            Limit=1,
        )
        items = resp.get("Items", [])
        if items:
            return items[0]["incident_id"]
    except Exception:
        pass
    return None


def handler(event, context):
    region = os.environ.get("AWS_REGION", "unknown")
    failures = []

    for record in event.get("Records", []):
        try:
            eb_event = json.loads(record["body"])
            detail = eb_event.get("detail", {})
            meta = detail.get("metadata", {})
            data = detail.get("data", {})

            detail_type = eb_event.get("detail-type", "")
            task_id = meta.get("task_id", "")
            exec_id = meta.get("execution_id", "")
            space_id = meta.get("agent_space_id", "")
            status = data.get("status", detail_type)

            if not task_id:
                continue

            # Resolve incident_id
            incident_id = None
            if detail_type == "Investigation Created":
                # First event — call agent API to get title and extract incident_id
                incident_id = resolve_incident_id(task_id, space_id, region)
            else:
                # Subsequent events — look up from DynamoDB
                incident_id = get_incident_id_from_task(task_id)

            if not incident_id:
                print(f"RETRY: no incident_id for task={task_id} ({detail_type})")
                failures.append({"itemIdentifier": record["messageId"]})
                continue

            # Write/update DynamoDB keyed by incident_id
            update_expr = "SET #s = :s, detail_type = :dt, task_id = :tid, space_id = :sid, #r = :r, last_updated = :ts"
            expr_values = {
                ":s": status,
                ":dt": detail_type,
                ":tid": task_id,
                ":sid": space_id,
                ":r": region,
                ":ts": int(time.time()),
            }
            expr_names = {"#s": "status", "#r": "region"}
            if exec_id:
                update_expr += ", execution_id = :eid"
                expr_values[":eid"] = exec_id

            table.update_item(
                Key={"incident_id": incident_id},
                UpdateExpression=update_expr,
                ExpressionAttributeValues=expr_values,
                ExpressionAttributeNames=expr_names,
            )
            print(f"OK: {incident_id} → {detail_type} ({status})")

        except Exception as e:
            print(f"ERROR: {e} | record={record.get('body', '')[:200]}")

    return {"batchItemFailures": failures}

"""
Neptune Feeder Lambda — triggered by DynamoDB Streams on fis-chaos-investigations table.

Reads investigation status changes and writes graph nodes/edges to Neptune:
- Investigation nodes (task_id, workspace, region, timestamp, status)
- Resource nodes (from affected_resources)
- Edges: caused_by, affects, cascades_to (from cascade_graph)

Graph enables cross-workspace dependency visualization and blast radius queries.
"""
import json
import os

from neptune_client import upsert_vertex, upsert_edge


def process_record(record):
    """Process a single DynamoDB Stream record into graph operations."""
    if record["eventName"] == "REMOVE":
        return

    new_image = record.get("dynamodb", {}).get("NewImage", {})
    if not new_image:
        return

    # Extract fields (DynamoDB JSON format)
    incident_id = new_image.get("incident_id", {}).get("S", "")
    task_id = new_image.get("task_id", {}).get("S", "")
    space_id = new_image.get("space_id", {}).get("S", "")
    region = new_image.get("region", {}).get("S", "")
    status = new_image.get("detail_type", {}).get("S", "")
    routed_to = new_image.get("routed_to", {}).get("S", "")

    if not incident_id:
        return

    # 1. Upsert Investigation node
    upsert_vertex(f"inv:{incident_id}", "Investigation", {
        "incident_id": incident_id,
        "task_id": task_id,
        "space_id": space_id,
        "region": region,
        "status": status,
        "routed_to": routed_to,
    })

    # 2. Upsert Workspace node + edge
    if space_id:
        upsert_vertex(f"ws:{space_id}", "Workspace", {
            "space_id": space_id,
            "region": region,
        })
        upsert_edge(f"inv:{incident_id}", f"ws:{space_id}", "investigated_by")

    # 3. Process affected_resources (if present)
    resources_raw = new_image.get("affected_resources", {}).get("L", [])
    for res in resources_raw:
        resource_name = res.get("S", "")
        if resource_name:
            res_id = f"res:{resource_name.replace(' ', '_').lower()}"
            upsert_vertex(res_id, "Resource", {"name": resource_name})
            upsert_edge(f"inv:{incident_id}", res_id, "affects")

    # 4. Process cascade_graph (if present)
    cascade_raw = new_image.get("cascade_graph", {}).get("L", [])
    for entry in cascade_raw:
        m = entry.get("M", {})
        from_node = m.get("from", {}).get("S", "")
        to_list = m.get("to", {}).get("L", [])
        if from_node:
            from_id = f"cause:{from_node}"
            upsert_vertex(from_id, "Cause", {"name": from_node})
            upsert_edge(f"inv:{incident_id}", from_id, "root_cause")
            for to_item in to_list:
                to_node = to_item.get("S", "")
                if to_node:
                    to_id = f"cause:{to_node}"
                    upsert_vertex(to_id, "Cause", {"name": to_node})
                    upsert_edge(from_id, to_id, "cascades_to")

    # 5. Process resource_arns (real ARNs extracted from RCA — links to Config InfraResource nodes)
    arns_raw = new_image.get("resource_arns", {}).get("L", [])
    for arn_item in arns_raw:
        arn = arn_item.get("S", "")
        if arn.startswith("arn:aws:"):
            # Store as a typed node; edge to InfraResource created by matching resource_id
            res_id = arn.split("/")[-1].split(":")[-1]  # last segment of ARN
            arn_node_id = f"arn:{arn}"
            upsert_vertex(arn_node_id, "ArnResource", {"arn": arn, "resource_id": res_id})
            upsert_edge(f"inv:{incident_id}", arn_node_id, "affects_resource")
            # Link to matching InfraResource if it exists (by resource_id)
            try:
                from neptune_client import neptune_query
                safe_id = res_id.replace("'", "\\'")
                neptune_query(
                    f"g.V().hasLabel('InfraResource').has('resource_id', '{safe_id}')"
                    f".as('cfg').V('{arn_node_id}').addE('same_as').to('cfg')"
                    f".iterate()"
                )
            except Exception:
                pass  # InfraResource may not exist yet — Config sync will catch up
        elif "/" in arn:
            # K8s path: namespace/kind/name
            upsert_vertex(f"k8s:{arn}", "K8sResource", {"path": arn})
            upsert_edge(f"inv:{incident_id}", f"k8s:{arn}", "affects_k8s")

    # 6. Link investigations (LINKED status)
    primary_task = new_image.get("primary_task_id", {}).get("S", "")
    if primary_task and "Linked" in status:
        upsert_edge(f"inv:{incident_id}", f"inv:{primary_task}", "linked_to")

    print(f"Processed: {incident_id} status={status} resources={len(resources_raw)} cascades={len(cascade_raw)}")


def handler(event, context):
    for record in event.get("Records", []):
        try:
            process_record(record)
        except Exception as e:
            print(f"Error processing record: {e}")
            # Don't fail the batch — log and continue
    return {"batchItemFailures": []}

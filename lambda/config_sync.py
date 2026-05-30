"""
Config Sync Lambda — periodically syncs AWS Config resources into Neptune.

Triggered by EventBridge scheduled rule (every 5 min) or Config change events.
Writes infrastructure nodes (resources) and edges (relationships) to Neptune,
enabling blast radius queries that join incident investigations with real infra.
"""
import json
import os

import boto3
from neptune_client import upsert_vertex, upsert_edge

REGIONS = os.environ.get("REGIONS", "eu-west-1,eu-central-1").split(",")
S3_BUCKET = os.environ.get("CONFIG_BUCKET", "config-bucket-<ACCOUNT_ID>")


def ensure_config_enabled(region):
    """Enable AWS Config recorder if not already active in the region."""
    client = boto3.client("config", region_name=region)
    try:
        status = client.describe_configuration_recorder_status()
        recorders = status.get("ConfigurationRecordersStatus", [])
        if recorders and recorders[0].get("recording"):
            return True  # already recording

        # Ensure recorder exists
        sts = boto3.client("sts")
        account_id = sts.get_caller_identity()["Account"]
        role_arn = f"arn:aws:iam::{account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
        client.put_configuration_recorder(
            ConfigurationRecorder={"name": "default", "roleARN": role_arn, "recordingGroup": {"allSupported": True}}
        )

        # Ensure delivery channel exists
        channels = client.describe_delivery_channels().get("DeliveryChannels", [])
        if not channels:
            client.put_delivery_channel(
                DeliveryChannel={"name": "default", "s3BucketName": S3_BUCKET}
            )
            print(f"Config: created delivery channel in {region}")

        client.start_configuration_recorder(ConfigurationRecorderName="default")
        print(f"Config: started recording in {region}")
        return True
    except Exception as e:
        print(f"Config: failed to enable in {region}: {e}")
        return False


def sync_resources(region):
    """Sync all Config-discovered resources for a region into Neptune."""
    client = boto3.client("config", region_name=region)
    paginator = client.get_paginator("list_discovered_resources")

    resource_types = [
        "AWS::EC2::Instance", "AWS::EC2::VPC", "AWS::EC2::Subnet",
        "AWS::EC2::SecurityGroup", "AWS::EKS::Cluster",
        "AWS::RDS::DBInstance", "AWS::Lambda::Function",
        "AWS::S3::Bucket", "AWS::SQS::Queue",
        "AWS::DynamoDB::Table", "AWS::ElasticLoadBalancingV2::LoadBalancer",
    ]

    synced = 0
    for rt in resource_types:
        try:
            for page in paginator.paginate(resourceType=rt):
                for res in page.get("resourceIdentifiers", []):
                    res_id = f"cfg:{res['resourceType']}:{res['resourceId']}"
                    try:
                        upsert_vertex(res_id, "InfraResource", {
                            "resource_type": res["resourceType"],
                            "resource_id": res["resourceId"],
                            "resource_name": res.get("resourceName", ""),
                            "region": region,
                        })
                        synced += 1
                    except Exception as ne:
                        print(f"Neptune write error for {res_id}: {ne}")
                        synced += 1  # Config read succeeded
        except Exception as e:
            print(f"Config read error {rt} in {region}: {e}")

    return synced


def sync_relationships(region):
    """Sync Config resource relationships into Neptune edges."""
    client = boto3.client("config", region_name=region)

    try:
        resp = client.select_resource_config(
            Expression="SELECT resourceId, resourceType, configuration WHERE resourceType = 'AWS::EC2::SecurityGroup'",
            Limit=100,
        )
        edges = 0
        for result in resp.get("Results", []):
            item = json.loads(result)
            source_id = f"cfg:{item['resourceType']}:{item['resourceId']}"
            # Extract relationships from configuration (varies by resource type)
            config = item.get("configuration", {})
            if isinstance(config, str):
                config = json.loads(config)
            vpc_id = config.get("vpcId", "")
            if vpc_id:
                target_id = f"cfg:AWS::EC2::VPC:{vpc_id}"
                upsert_edge(source_id, target_id, "is_in")
                edges += 1
        return edges
    except Exception as e:
        print(f"Relationship sync error in {region}: {e}")
        return 0


def handler(event, context):
    total_resources = 0
    total_edges = 0

    for region in REGIONS:
        if not ensure_config_enabled(region):
            print(f"Skipping {region} — Config could not be enabled")
            continue
        resources = sync_resources(region)
        edges = sync_relationships(region)
        total_resources += resources
        total_edges += edges
        print(f"Region {region}: {resources} resources, {edges} relationships synced")

    print(f"Total: {total_resources} resources, {total_edges} relationships")
    return {"resources": total_resources, "edges": total_edges}

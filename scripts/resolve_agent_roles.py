#!/usr/bin/env python3
"""Resolve DevOps Agent IAM role ARNs by region from trust policies."""
import json, sys, boto3

def main():
    query = json.load(sys.stdin)
    primary_region = query.get("primary_region", "")
    secondary_region = query.get("secondary_region", "")
    
    iam = boto3.client("iam")
    result = {"primary_role_arn": "", "secondary_role_arn": ""}
    
    paginator = iam.get_paginator("list_roles")
    for page in paginator.paginate():
        for role in page.get("Roles", []):
            name = role["RoleName"]
            if "DevOpsAgentRole-AgentSpace" not in name:
                continue
            trust = json.dumps(role.get("AssumeRolePolicyDocument", {}))
            if primary_region in trust and not result["primary_role_arn"]:
                result["primary_role_arn"] = role["Arn"]
            elif secondary_region in trust and not result["secondary_role_arn"]:
                result["secondary_role_arn"] = role["Arn"]
            if result["primary_role_arn"] and result["secondary_role_arn"]:
                break
    
    json.dump(result, sys.stdout)

if __name__ == "__main__":
    main()

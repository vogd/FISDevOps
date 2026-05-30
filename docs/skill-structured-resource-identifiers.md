# Agent Skill: structured-resource-identifiers

## Console Setup

**Agent Space → Skills → Add skill**

| Field | Value |
|-------|-------|
| Name | `structured-resource-identifiers` |
| Agent Type | Incident RCA |

## Description (paste into skill description field)

```
At the end of every investigation, include a section titled "## Affected Resource Identifiers" containing a bullet list of every AWS resource and Kubernetes resource you accessed or identified as affected during the investigation.

Format requirements:
- AWS resources: full ARN (e.g., arn:aws:eks:eu-west-1:<ACCOUNT_ID>:cluster/chaos-cluster)
- CloudWatch alarms: full ARN (e.g., arn:aws:cloudwatch:eu-west-1:<ACCOUNT_ID>:alarm:chaos-pod-restart)
- IAM roles: full ARN (e.g., arn:aws:iam::<ACCOUNT_ID>:role/fis-chaos-role)
- Kubernetes resources: namespace/kind/name (e.g., app/deployment/checkout, app/pod/ui-76f758b4bf-wblbt, app/statefulset/catalog-mysql)
- EKS cluster: full ARN

Include resources that are:
1. Directly affected (the failing component)
2. Indirectly affected (downstream services impacted by cascading failure)
3. Related infrastructure (the alarm that fired, the cluster hosting the workload)

Example output:
## Affected Resource Identifiers
- arn:aws:eks:eu-west-1:<ACCOUNT_ID>:cluster/chaos-cluster
- arn:aws:cloudwatch:eu-west-1:<ACCOUNT_ID>:alarm:chaos-pod-restart
- app/deployment/checkout
- app/pod/checkout-99585c9d4-5tnnb
- app/service/checkout

This data is used for automated correlation with AWS Config resource inventory.
```

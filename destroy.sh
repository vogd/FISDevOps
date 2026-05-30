#!/bin/bash
set -o pipefail

# Auto-navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

export AWS_PAGER=""
export AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_REGION="${AWS_REGION:-us-west-2}"
export CLUSTER_NAME="${CLUSTER_NAME:-chaos-cluster}"
export AGENT_REGION_PRIMARY="${AGENT_REGION_PRIMARY:-$AWS_REGION}"
export AGENT_REGION_SECONDARY="${AGENT_REGION_SECONDARY:-$AWS_REGION}"

echo "============================================================"
echo "  FIS Chaos Testing — Full Teardown"
echo "============================================================"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID | Region: $AWS_REGION | Cluster: $CLUSTER_NAME"
echo "Agent regions: $AGENT_REGION_PRIMARY (primary), $AGENT_REGION_SECONDARY (secondary)"
echo ""
echo "NOTE: S3 bucket (fis-chaos-results-$ACCOUNT_ID) is PRESERVED for RCA history."
echo ""

# ============================================================================
# STEP 1: Uninstall ArgoCD (stops ELB recreation)
# ============================================================================
echo "Step 1: Uninstalling ArgoCD..."
export KUBECONFIG="/tmp/$CLUSTER_NAME"
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true
helm uninstall argo-cd -n argocd 2>/dev/null || true
kubectl delete svc --all -n argocd 2>/dev/null || true

# ============================================================================
# STEP 2: Delete ELBs (classic + ALB/NLB)
# ============================================================================
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Step 2: Deleting load balancers in VPC $VPC_ID..."
  aws elb describe-load-balancers --region $AWS_REGION \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null | \
    tr '\t' '\n' | while read -r lb; do
      [ -n "$lb" ] && echo "  Deleting ELB: $lb" && \
        aws elb delete-load-balancer --load-balancer-name "$lb" --region $AWS_REGION
    done
  aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null | \
    tr '\t' '\n' | while read -r arn; do
      [ -n "$arn" ] && echo "  Deleting ALB/NLB" && \
        aws elbv2 delete-load-balancer --load-balancer-arn "$arn" --region $AWS_REGION
    done
  echo "  Waiting 30s..."
  sleep 30
fi

# ============================================================================
# STEP 3: Delete security groups (attempt 1)
# ============================================================================
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Step 3: Deleting security groups..."
  aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID \
    --region $AWS_REGION --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null | \
    tr '\t' '\n' | while read -r sg; do
      [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" --region $AWS_REGION 2>/dev/null && echo "  ✓ $sg"
    done
  sleep 15
  # Attempt 2
  aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID \
    --region $AWS_REGION --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null | \
    tr '\t' '\n' | while read -r sg; do
      [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" --region $AWS_REGION 2>/dev/null && echo "  ✓ $sg (retry)"
    done
fi

# ============================================================================
# STEP 4: Remove tag resources from Terraform state (SCP blocks ec2:DeleteTags)
# ============================================================================
echo "Step 4: Cleaning terraform state..."
cd amazon-eks-chaos/terraform 2>/dev/null || true
terraform state rm 'module.eks.aws_ec2_tag.cluster_primary_security_group["Blueprint"]' 2>/dev/null || true
terraform state rm 'module.eks.aws_ec2_tag.cluster_primary_security_group["GithubRepo"]' 2>/dev/null || true
cd "$PROJECT_ROOT"

# ============================================================================
# STEP 5: Terraform destroy (FIS layer + EKS)
# ============================================================================
echo "Step 5: Terraform destroy..."

# FIS layer
if [ -f terraform/terraform.tfstate ]; then
  echo "  Destroying FIS layer (includes Neptune, CloudFront, Global Endpoint, DynamoDB)..."
  cd terraform
  terraform destroy -auto-approve \
    -var="region=$AWS_REGION" \
    -var="primary_agent_region=$AGENT_REGION_PRIMARY" \
    -var="secondary_agent_region=$AGENT_REGION_SECONDARY" 2>&1 || echo "  ⚠ Terraform destroy had errors (continuing with CLI cleanup)"
  cd "$PROJECT_ROOT"
fi

# EKS cluster
if [ -f amazon-eks-chaos/terraform/terraform.tfstate ] || [ -d amazon-eks-chaos/terraform/terraform.tfstate.d ]; then
  echo "  Destroying EKS cluster via terraform..."
  cd amazon-eks-chaos/terraform
  export KUBECONFIG="/tmp/$CLUSTER_NAME"
  aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true
  terraform destroy -var="kubernetes_version=1.31" -auto-approve || true
  cd "$PROJECT_ROOT"
fi

# ============================================================================
# STEP 6: CLI fallback — delete Neptune, CloudFront, Global Endpoint if still exist
# ============================================================================
echo "Step 6a: Cleaning Neptune..."
NEPTUNE_CLUSTER="fis-chaos-investigations"
aws neptune describe-db-clusters --db-cluster-identifier $NEPTUNE_CLUSTER --region $AWS_REGION &>/dev/null && {
  # Delete instances first
  for INST in $(aws neptune describe-db-instances --region $AWS_REGION \
    --query "DBInstances[?DBClusterIdentifier=='$NEPTUNE_CLUSTER'].DBInstanceIdentifier" --output text 2>/dev/null); do
    echo "  Deleting Neptune instance: $INST"
    aws neptune delete-db-instance --db-instance-identifier "$INST" --region $AWS_REGION --skip-final-snapshot 2>/dev/null || true
  done
  echo "  Waiting for instances to delete..."
  sleep 60
  echo "  Deleting Neptune cluster..."
  aws neptune delete-db-cluster --db-cluster-identifier $NEPTUNE_CLUSTER --skip-final-snapshot --region $AWS_REGION 2>/dev/null || true
  echo "  ✓ Neptune deletion initiated"
} || echo "  Neptune cluster not found (already deleted)"

# Clean Neptune networking leftovers
echo "  Cleaning Neptune networking..."
aws neptune delete-db-subnet-group --db-subnet-group-name fis-chaos-neptune --region $AWS_REGION 2>/dev/null || true

# Delete orphaned ENIs (Lambda VPC functions leave these behind)
echo "  Deleting Neptune notebook (releases ENI)..."
aws sagemaker stop-notebook-instance --notebook-instance-name aws-neptune-mynotebook --region $AWS_REGION 2>/dev/null || true
sleep 10
aws sagemaker delete-notebook-instance --notebook-instance-name aws-neptune-mynotebook --region $AWS_REGION 2>/dev/null && echo "  ✓ Notebook deleted" || true
sleep 20
echo "  Deleting orphaned ENIs..."
for SG_NAME in fis-chaos-neptune fis-chaos-neptune-feeder; do
  SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --region $AWS_REGION \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ] && continue
  for ENI in $(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=$SG_ID" --region $AWS_REGION \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
    ATTACH_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --region $AWS_REGION \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null)
    [ -n "$ATTACH_ID" ] && [ "$ATTACH_ID" != "None" ] && \
      aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region $AWS_REGION 2>/dev/null
    sleep 5
    aws ec2 delete-network-interface --network-interface-id "$ENI" --region $AWS_REGION 2>/dev/null && echo "    ✓ ENI $ENI deleted"
  done
done
sleep 10

for SG_NAME in fis-chaos-neptune fis-chaos-neptune-feeder; do
  SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" --region $AWS_REGION \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ] && \
    aws ec2 delete-security-group --group-id "$SG_ID" --region $AWS_REGION 2>/dev/null && echo "  ✓ SG $SG_NAME deleted"
done
for CIDR in 172.31.200.0/24 172.31.201.0/24; do
  SUB_ID=$(aws ec2 describe-subnets --filters "Name=cidr-block,Values=$CIDR" --region $AWS_REGION \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
  [ -n "$SUB_ID" ] && [ "$SUB_ID" != "None" ] && \
    aws ec2 delete-subnet --subnet-id "$SUB_ID" --region $AWS_REGION 2>/dev/null && echo "  ✓ Subnet $CIDR deleted"
done

echo "Step 6b: Cleaning CloudFront..."
CF_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='FIS Chaos Incident Graph'].Id" --output text 2>/dev/null)
if [ -n "$CF_ID" ] && [ "$CF_ID" != "None" ]; then
  echo "  Disabling CloudFront $CF_ID..."
  ETAG=$(aws cloudfront get-distribution-config --id "$CF_ID" --query 'ETag' --output text)
  aws cloudfront get-distribution-config --id "$CF_ID" --query 'DistributionConfig' --output json | \
    python3 -c "import json,sys; c=json.load(sys.stdin); c['Enabled']=False; print(json.dumps(c))" | \
    aws cloudfront update-distribution --id "$CF_ID" --if-match "$ETAG" --distribution-config file:///dev/stdin 2>/dev/null || true
  echo "  ⚠ CloudFront disabled (takes ~15min to fully delete — run 'aws cloudfront delete-distribution --id $CF_ID --if-match <etag>' later)"
fi

echo "Step 6c: Cleaning EventBridge Global Endpoint..."
aws events delete-endpoint --name fis-chaos-global --region $AWS_REGION 2>/dev/null && echo "  ✓ Global Endpoint deleted" || true

echo "Step 6d: Cleaning Route53 health check..."
for HC in $(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.AlarmIdentifier.Name=='fis-chaos-global-endpoint-health'].Id" --output text 2>/dev/null); do
  aws route53 delete-health-check --health-check-id "$HC" 2>/dev/null && echo "  ✓ Health check $HC deleted"
done

echo "Step 6e: Cleaning DynamoDB..."
aws dynamodb delete-table --table-name fis-chaos-investigations --region $AWS_REGION 2>/dev/null && echo "  ✓ DynamoDB table deleted" || true

# ============================================================================
# STEP 6f: CLI fallback — delete EKS if still exists
# ============================================================================
if aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION &>/dev/null; then
  echo "Step 6f: Cluster still exists — deleting via CLI..."
  # Nodegroups
  for NG in $(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION --query 'nodegroups[*]' --output text 2>/dev/null); do
    echo "  Deleting nodegroup: $NG"
    aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name "$NG" --region $AWS_REGION || true
    echo "  Waiting for nodegroup $NG deletion..."
    aws eks wait nodegroup-deleted --cluster-name $CLUSTER_NAME --nodegroup-name "$NG" --region $AWS_REGION 2>/dev/null || true
    echo "  ✓ Nodegroup $NG deleted"
  done
  # Addons
  for ADDON in $(aws eks list-addons --cluster-name $CLUSTER_NAME --region $AWS_REGION --query 'addons[*]' --output text 2>/dev/null); do
    aws eks delete-addon --cluster-name $CLUSTER_NAME --addon-name "$ADDON" --region $AWS_REGION || true
  done
  sleep 10
  # Cluster
  echo "  Deleting cluster..."
  aws eks delete-cluster --name $CLUSTER_NAME --region $AWS_REGION || true
  echo "  Waiting for cluster deletion (up to 10 min)..."
  aws eks wait cluster-deleted --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true
  echo "  ✓ Cluster deleted"
fi

# ============================================================================
# STEP 7: Delete orphaned security groups + VPC
# ============================================================================
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Step 7: Final VPC cleanup..."
  aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID \
    --region $AWS_REGION --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null | \
    tr '\t' '\n' | while read -r sg; do
      [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" --region $AWS_REGION 2>/dev/null
    done
  aws ec2 delete-vpc --vpc-id $VPC_ID --region $AWS_REGION 2>/dev/null && echo "  ✓ VPC deleted" || echo "  VPC may have remaining dependencies"
fi

# ============================================================================
# STEP 8: Delete DevOps Agent spaces (terraform workspaces + CLI fallback)
# ============================================================================
echo "Step 8: Deleting DevOps Agent spaces..."

# Destroy via terraform workspaces first (prevents orphaned state on redeploy)
if [ -d "sample-aws-devops-agent-terraform" ]; then
  cd sample-aws-devops-agent-terraform
  terraform init -input=false 2>/dev/null || true
  for WS in primary secondary; do
    if terraform workspace select "$WS" 2>/dev/null; then
      echo "  Destroying workspace '$WS'..."
      terraform destroy -auto-approve 2>/dev/null || true
      terraform workspace select default 2>/dev/null || true
      terraform workspace delete "$WS" 2>/dev/null || true
    fi
  done
  cd "$PROJECT_ROOT"
fi

# CLI fallback: delete spaces by tag OR by known name pattern
echo "  Checking for spaces to delete..."
python3 -c "
import boto3
account = '$ACCOUNT_ID'
for region in ['$AGENT_REGION_PRIMARY', '$AGENT_REGION_SECONDARY']:
    client = boto3.client('devops-agent', region_name=region)
    try:
        spaces = client.list_agent_spaces().get('agentSpaces', [])
    except Exception:
        continue
    for space in spaces:
        space_id = space['agentSpaceId']
        name = space.get('name', '')
        should_delete = name in ('primaryspace', 'secondaryspace')
        if not should_delete:
            try:
                tags = client.list_tags_for_resource(
                    resourceArn=f'arn:aws:aidevops:{region}:{account}:agentspace/{space_id}'
                ).get('tags', {})
                if isinstance(tags, dict):
                    should_delete = tags.get('app') == 'devopsagent'
                else:
                    should_delete = any(t.get('Key') == 'app' and t.get('Value') == 'devopsagent' for t in tags)
            except Exception:
                pass
        if should_delete:
            print(f'  Deleting {name} ({space_id}) in {region}...')
            try:
                client.delete_agent_space(agentSpaceId=space_id)
                print(f'  ✓ Deleted')
            except Exception as e:
                print(f'  ⚠ {e}')
" 2>/dev/null || true

# ============================================================================
# STEP 9: Delete IRSA IAM roles (with policy detachment)
# ============================================================================
echo "Step 9: Deleting IAM roles..."
for ROLE in ${CLUSTER_NAME}-ebs-csi-driver ${CLUSTER_NAME}-cloudwatch-agent ${CLUSTER_NAME}-ec2-ssm-role fis-chaos-role fis-chaos-rca-writer fis-chaos-rca-writer-secondary fis-chaos-scorer fis-chaos-webhook-proxy fis-chaos-global-forwarder fis-chaos-dispatcher fis-chaos-graph-builder fis-chaos-neptune-feeder fis-chaos-config-sync fis-chaos-neptune-notebook; do
  aws iam list-attached-role-policies --role-name $ROLE --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null | \
    tr '\t' '\n' | while read -r arn; do
      [ -n "$arn" ] && aws iam detach-role-policy --role-name $ROLE --policy-arn "$arn"
    done
  aws iam list-role-policies --role-name $ROLE --query 'PolicyNames[*]' --output text 2>/dev/null | \
    tr '\t' '\n' | while read -r pol; do
      [ -n "$pol" ] && aws iam delete-role-policy --role-name $ROLE --policy-name "$pol"
    done
  aws iam delete-role --role-name $ROLE 2>/dev/null && echo "  ✓ $ROLE"
done

# ============================================================================
# STEP 10: Clean EKS orphans (KMS alias, log group, instance profile)
# ============================================================================
echo "Step 10: Cleaning EKS orphans..."
aws kms delete-alias --alias-name "alias/eks/$CLUSTER_NAME" --region $AWS_REGION 2>/dev/null && echo "  ✓ KMS alias deleted" || true
aws logs delete-log-group --log-group-name "/aws/eks/$CLUSTER_NAME/cluster" --region $AWS_REGION 2>/dev/null && echo "  ✓ EKS log group deleted" || true
aws iam remove-role-from-instance-profile --instance-profile-name ${CLUSTER_NAME}-ec2-ssm-profile --role-name ${CLUSTER_NAME}-ec2-ssm-role 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name ${CLUSTER_NAME}-ec2-ssm-profile 2>/dev/null && echo "  ✓ Instance profile deleted" || true

# ============================================================================
# STEP 11: Tag-based orphan cleanup (safety net)
# ============================================================================
echo "Step 11: Cleaning orphaned resources by tag (app=devopsagent)..."
for REGION in $AWS_REGION $AGENT_REGION_PRIMARY $AGENT_REGION_SECONDARY; do
  ARNS=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=app,Values=devopsagent \
    --region $REGION \
    --query 'ResourceTagMappingList[*].ResourceARN' --output text 2>/dev/null)
  [ -z "$ARNS" ] && continue
  for ARN in $ARNS; do
    echo "  $ARN"
    case "$ARN" in
      *:lambda:*:function:*) aws lambda delete-function --function-name "${ARN##*:function:}" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:logs:*:log-group:*) aws logs delete-log-group --log-group-name "$(echo $ARN | sed 's/.*:log-group://' | sed 's/:.*$//')" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:sqs:*) aws sqs delete-queue --queue-url "https://sqs.$REGION.amazonaws.com/$ACCOUNT_ID/fis-chaos-agent-events" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:events:*:rule/*) aws events remove-targets --rule "${ARN##*rule/}" --ids $(aws events list-targets-by-rule --rule "${ARN##*rule/}" --region $REGION --query 'Targets[*].Id' --output text 2>/dev/null) --region $REGION 2>/dev/null; aws events delete-rule --name "${ARN##*rule/}" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:fis:*:experiment-template/*) aws fis delete-experiment-template --id "${ARN##*/}" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:apigateway:*::/restapis/[a-z0-9]*) API_ID=$(echo "$ARN" | grep -o 'restapis/[^/]*' | cut -d/ -f2); [ -n "$API_ID" ] && aws apigateway delete-rest-api --rest-api-id "$API_ID" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:apigateway:*::/usageplans/*) aws apigateway delete-usage-plan --usage-plan-id "${ARN##*/}" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:apigateway:*::/apikeys/*) aws apigateway delete-api-key --api-key "${ARN##*/}" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:secretsmanager:*) aws secretsmanager delete-secret --secret-id "$ARN" --force-delete-without-recovery --region $REGION 2>/dev/null && echo "    ✓" ;;
      *:eks:*:access-entry*) aws eks delete-access-entry --cluster-name $CLUSTER_NAME --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/fis-chaos-role" --region $REGION 2>/dev/null && echo "    ✓" ;;
      *) echo "    (skip)" ;;
    esac
  done
done

# ============================================================================
# STEP 12: Clean local state files
# ============================================================================
echo "Step 12: Cleaning local state..."
rm -rf amazon-eks-chaos/terraform/terraform.tfstate*
rm -rf amazon-eks-chaos/terraform/terraform.tfstate.d
rm -rf sample-aws-devops-agent-terraform/terraform.tfstate.d
rm -rf sample-aws-devops-agent-terraform/.terraform
rm -rf terraform/terraform.tfstate*
rm -rf terraform/ha/terraform.tfstate*
rm -rf .venv
rm -f templates.json

echo ""
echo "============================================================"
echo "  ✓ Teardown complete"
echo "  NOTE: S3 bucket fis-chaos-results-$ACCOUNT_ID PRESERVED"
echo "============================================================"

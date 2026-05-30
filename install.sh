#!/bin/bash
set -euo pipefail

# Disable AWS CLI pager
export AWS_PAGER=""
# Note: not using -e (errexit) because many commands intentionally return non-zero
# (e.g., "already exists" checks). Each critical command has explicit error handling.

# Auto-navigate to project root (parent of this script's directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"
echo "Working directory: $(pwd)"

# ============================================================================
# FIS Chaos Testing + DevOps Agent — Full Deployment Script
# ============================================================================
# Deploys: EKS cluster, Chaos Mesh, sample app, FIS experiments,
#          DevOps Agent spaces (primary + DR), webhook proxy, scoring infra
#
# Prerequisites:
#   - AWS CLI, Terraform >= 1.5, kubectl, helm, python3.12
#   - AWS credentials configured (profile or env vars)
#
# Usage:
#   chmod +x install.sh
#   ./install.sh
# ============================================================================

# --- USER CONFIGURATION (edit these) ---
export AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_REGION="${AWS_REGION:-us-west-2}"              # EKS/FIS region
export AGENT_REGION_PRIMARY="${AGENT_REGION_PRIMARY:-us-east-1}"  # Primary agent space
export AGENT_REGION_SECONDARY="${AGENT_REGION_SECONDARY:-us-west-2}"  # DR agent space
export KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.31}"
export DB_PASSWORD="${DB_PASSWORD:-Ch40sT3st2026!}"
export CLUSTER_NAME="${CLUSTER_NAME:-chaos-cluster}"

# --- DERIVED (auto-populated) ---
ACCOUNT_ID=""
OIDC_ID=""
PRIMARY_SPACE_ID="${PRIMARY_SPACE_ID:-}"
SECONDARY_SPACE_ID="${SECONDARY_SPACE_ID:-}"
PRIMARY_WEBHOOK_URL="${PRIMARY_WEBHOOK_URL:-}"
PRIMARY_WEBHOOK_SECRET="${PRIMARY_WEBHOOK_SECRET:-}"
SECONDARY_WEBHOOK_URL="${SECONDARY_WEBHOOK_URL:-}"
SECONDARY_WEBHOOK_SECRET="${SECONDARY_WEBHOOK_SECRET:-}"
RESULTS_BUCKET=""

# --- SKILL TEXT (shared between both agent spaces) ---
SKILL_DESCRIPTION='Read historical results from S3 bucket BUCKET_PLACEHOLDER at the start of every investigation regardless of type. Step 1: List s3://BUCKET_PLACEHOLDER/experiments/ to find prefix matching the affected service. Step 2: Read 2-3 most recent JSON files. Each contains devops_agent_rca (root cause markdown), findings (cascade_graph showing propagation), ground_truth (fault category), affected_resources (blast radius), mitigation_action (remediation). Step 3: Compare current symptoms against historical findings for recurring patterns. If matched, cite as known issue with the historical incident_id. Step 4: Read scorecards/latest.json for detection accuracy and common failure modes. Prioritize hypotheses based on historically frequent root causes. Apply historical context before new hypotheses to avoid redundant analysis and ensure continuity across failover.'

# ============================================================================
print_step() {
  echo ""
  echo "============================================================"
  echo "  STEP $1: $2"
  echo "  WHY: $3"
  echo "============================================================"
}

check_prereqs() {
  print_step "0" "Checking prerequisites" "Ensure all tools are installed"
  MISSING=()
  for cmd in aws terraform kubectl helm python3.12; do
    if command -v $cmd &>/dev/null; then
      echo "  ✓ $cmd ($(command -v $cmd))"
    else
      echo "  ✗ $cmd NOT FOUND"
      MISSING+=($cmd)
    fi
  done

  if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "  ERROR: Missing tools: ${MISSING[*]}"
    echo ""
    echo "  Install on macOS:"
    echo "    brew install terraform kubectl helm python@3.12 awscli"
    echo ""
    echo "  Install on Linux (Ubuntu/Debian):"
    echo "    # Terraform"
    echo "    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg"
    echo "    echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list"
    echo "    sudo apt update && sudo apt install terraform"
    echo ""
    echo "    # kubectl"
    echo "    curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    echo "    chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
    echo ""
    echo "    # Helm"
    echo "    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    echo ""
    echo "    # Python 3.12"
    echo "    sudo apt install python3.12 python3.12-venv"
    echo ""
    echo "    # AWS CLI"
    echo "    curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\""
    echo "    unzip awscliv2.zip && sudo ./aws/install"
    echo ""
    exit 1
  fi

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  echo "  ✓ AWS Account: $ACCOUNT_ID"
  echo "  ✓ Profile: $AWS_PROFILE"
  echo "  ✓ EKS Region: $AWS_REGION"
  echo "  ✓ Agent Primary: $AGENT_REGION_PRIMARY"
  echo "  ✓ Agent DR: $AGENT_REGION_SECONDARY"
}

# ============================================================================
step1_clone_eks_repo() {
  print_step "1" "Clone EKS Chaos Infra" "Provides VPC + EKS cluster Terraform modules"
  if [ -d "amazon-eks-chaos" ]; then
    echo "  → Already cloned, skipping"
  else
    git clone https://github.com/aws-samples/amazon-eks-chaos.git
    echo "  ✓ Cloned amazon-eks-chaos"
  fi
}

# ============================================================================
step2_deploy_eks() {
  print_step "2" "Deploy EKS Cluster" "Creates VPC, EKS cluster ($CLUSTER_NAME), managed node group (2x t3.large)"

  # Check if cluster already exists
  if aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION &>/dev/null; then
    echo "  → Cluster $CLUSTER_NAME already exists in $AWS_REGION, skipping terraform"
  else
    cd amazon-eks-chaos/terraform
    WORKSPACE="${ACCOUNT_ID}-${AWS_REGION}"
    terraform init -input=false
    terraform workspace new "$WORKSPACE" 2>/dev/null || terraform workspace select "$WORKSPACE"
    # Note: EBS CSI addon will timeout (~20 min) because it needs IRSA role
    # which can only be created after the cluster exists. This is expected.
    # The script fixes it immediately after with the IRSA role creation below.
    echo "  ⚠️  EBS CSI addon will timeout (~20 min) — this is expected."
    echo "  The script will fix it automatically after cluster creation."
    terraform apply -var="kubernetes_version=$KUBERNETES_VERSION" -auto-approve || true
    cd ../..
  fi

  # Configure kubectl
  export KUBECONFIG="/tmp/$CLUSTER_NAME"
  aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

  # Ensure deployer has EKS cluster admin access
  CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
  ROLE_ARN=$(echo "$CALLER_ARN" | sed 's|assumed-role/\(.*\)/.*|role/\1|' | sed 's|:sts:|:iam:|')
  echo "  Ensuring EKS access for $ROLE_ARN..."
  aws eks create-access-entry --cluster-name $CLUSTER_NAME --principal-arn "$ROLE_ARN" --type STANDARD --region $AWS_REGION 2>/dev/null || true
  aws eks associate-access-policy --cluster-name $CLUSTER_NAME --principal-arn "$ROLE_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster --region $AWS_REGION 2>/dev/null || true

  # Ensure EBS CSI driver has IRSA role
  OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
    --query 'cluster.identity.oidc.issuer' --output text | cut -d/ -f5)

  echo "  Ensuring IRSA role for EBS CSI driver..."
  aws iam create-role --role-name ${CLUSTER_NAME}-ebs-csi-driver \
    --assume-role-policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": {\"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}\"},
        \"Action\": \"sts:AssumeRoleWithWebIdentity\",
        \"Condition\": {\"StringEquals\": {
          \"oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub\": \"system:serviceaccount:kube-system:ebs-csi-controller-sa\",
          \"oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud\": \"sts.amazonaws.com\"
        }}
      }]
    }" 2>/dev/null || true

  aws iam attach-role-policy --role-name ${CLUSTER_NAME}-ebs-csi-driver \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy 2>/dev/null || true

  # Check addon status — only fix if not ACTIVE
  ADDON_STATUS=$(aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver \
    --region $AWS_REGION --query 'addon.status' --output text 2>/dev/null || echo "MISSING")

  if [ "$ADDON_STATUS" != "ACTIVE" ]; then
    echo "  EBS CSI addon status: $ADDON_STATUS — fixing..."
    aws eks delete-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver \
      --region $AWS_REGION 2>/dev/null || true
    sleep 15
    aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver \
      --service-account-role-arn arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-ebs-csi-driver \
      --region $AWS_REGION 2>/dev/null || true
  fi

  echo "  ✓ EKS cluster ready, EBS CSI driver configured"
}

# ============================================================================
step3_install_chaos_mesh() {
  print_step "3" "Install Chaos Mesh" "Provides fault injection CRDs (PodChaos, NetworkChaos, StressChaos, etc.)"
  helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
  helm repo update
  helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --version 2.7.0 --create-namespace 2>/dev/null || echo "  → Already installed"

  # Fix known webhook issue
  kubectl delete validatingwebhookconfigurations chaos-mesh-validation-auth 2>/dev/null || true
  echo "  ✓ Chaos Mesh installed"
}

# ============================================================================
step4_deploy_sample_app() {
  print_step "4" "Deploy Sample Application" "Retail store microservices (UI, checkout, catalog, orders, carts, assets) as fault targets"
  kubectl create namespace app 2>/dev/null || true
  kubectl create secret generic catalog-db --from-literal=username=catalog --from-literal=password=$DB_PASSWORD -n app 2>/dev/null || true
  kubectl create secret generic orders-db --from-literal=username=orders --from-literal=password=$DB_PASSWORD -n app 2>/dev/null || true
  kubectl apply -f amazon-eks-chaos/app/retail-store-sample-app.yaml -n app
  echo "  ✓ Sample app deployed"
  echo "  Waiting 30s for pods to start..."
  sleep 30
  kubectl get pods -n app --no-headers | awk '{print "    " $1 " → " $3}'
}

# ============================================================================
step5_enable_container_insights() {
  print_step "5" "Enable Container Insights" "Provides CloudWatch metrics (CPU, memory, restarts) for alarm-based detection"
  OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
    --query 'cluster.identity.oidc.issuer' --output text | cut -d/ -f5)

  aws iam create-role --role-name ${CLUSTER_NAME}-cloudwatch-agent \
    --assume-role-policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": {\"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}\"},
        \"Action\": \"sts:AssumeRoleWithWebIdentity\",
        \"Condition\": {\"StringEquals\": {
          \"oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub\": \"system:serviceaccount:amazon-cloudwatch:cloudwatch-agent\",
          \"oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud\": \"sts.amazonaws.com\"
        }}
      }]
    }" 2>/dev/null || true

  aws iam attach-role-policy --role-name ${CLUSTER_NAME}-cloudwatch-agent \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || true

  aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name amazon-cloudwatch-observability \
    --service-account-role-arn arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-cloudwatch-agent \
    --region $AWS_REGION 2>/dev/null || true

  echo "  ✓ Container Insights enabled"
}

# ============================================================================
step6_apply_rbac() {
  print_step "6" "Apply RBAC" "FIS gets Chaos Mesh access; DevOps Agent is BLOCKED from chaos-mesh namespace (must diagnose from symptoms only)"
  kubectl apply -f k8s/rbac-fis.yaml
  kubectl apply -f k8s/rbac-devops-agent.yaml
  echo "  ✓ RBAC applied"
  echo "    FIS → can create Chaos Mesh CRDs"
  echo "    DevOps Agent → can read app namespace only (chaos-mesh blocked)"

  # Force ArgoCD ELB to internal (no public IP exposure)
  kubectl annotate svc argo-cd-argocd-server -n argocd \
    service.beta.kubernetes.io/aws-load-balancer-internal="true" --overwrite 2>/dev/null || true
  echo "    ArgoCD → ELB set to internal (no public access)"
}

# ============================================================================
step7_deploy_fis_layer() {
  print_step "9" "Deploy FIS Layer + Scoring Infra" "Creates 10 FIS experiment templates, CloudWatch alarms, S3 bucket, Lambda scorer, EventBridge rules, SQS queues, webhook proxy"
  cd "$PROJECT_ROOT"

  cd terraform

  # Check if existing state belongs to a different account — if so, clean it
  if [ -f terraform.tfstate ]; then
    STATE_ACCOUNT=$(grep -o '"account_id": "[0-9]*"' terraform.tfstate 2>/dev/null | head -1 | grep -o '[0-9]*')
    if [ -n "$STATE_ACCOUNT" ] && [ "$STATE_ACCOUNT" != "$ACCOUNT_ID" ]; then
      echo "  ⚠️  Existing state belongs to account $STATE_ACCOUNT (current: $ACCOUNT_ID)"
      echo "  Removing stale state..."
      rm -f terraform.tfstate terraform.tfstate.backup
    fi
  fi

  terraform init -input=false

  # Import preserved S3 bucket if it exists but isn't in state
  BUCKET_NAME="fis-chaos-results-$ACCOUNT_ID"
  if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null && \
     ! terraform state show aws_s3_bucket.results &>/dev/null; then
    echo "  Importing existing S3 bucket $BUCKET_NAME into state..."
    terraform import \
      -var="region=$AWS_REGION" \
      -var="primary_agent_region=$AGENT_REGION_PRIMARY" \
      -var="secondary_agent_region=$AGENT_REGION_SECONDARY" \
      aws_s3_bucket.results "$BUCKET_NAME" 2>/dev/null || true
  fi

  # Validate required variables before writing secret
  if [ -z "$PRIMARY_WEBHOOK_URL" ] || [ -z "$PRIMARY_SPACE_ID" ]; then
    echo "  ERROR: Missing webhook URLs or space IDs. Step 8 may have failed."
    echo "  Re-run with credentials refreshed, or pass values as env vars."
    echo "  PRIMARY_SPACE_ID=$PRIMARY_SPACE_ID"
    echo "  PRIMARY_WEBHOOK_URL=$PRIMARY_WEBHOOK_URL"
    return 1
  fi

  # Check for orphaned resources from previous failed deploys (exclude S3 — intentionally preserved)
  ORPHANS=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=app,Values=devopsagent \
    --region $AWS_REGION \
    --query 'ResourceTagMappingList[?!contains(ResourceARN,`:s3:`)].ResourceARN' --output text 2>/dev/null | wc -w | tr -d ' ')
  if [ "$ORPHANS" -gt "0" ] && [ ! -f terraform.tfstate ]; then
    echo "  ⚠️  Found $ORPHANS orphaned resources tagged app=devopsagent but no terraform state."
    echo "  Run ./destroy.sh first to clean up, then re-run ./install.sh"
    return 1
  fi

  terraform apply -auto-approve \
    -var="region=$AWS_REGION" \
    -var="primary_agent_region=$AGENT_REGION_PRIMARY" \
    -var="secondary_agent_region=$AGENT_REGION_SECONDARY"

  # Write webhook endpoints to Secrets Manager (dynamic, not managed by terraform)
  echo "  Writing webhook endpoints to Secrets Manager..."
  aws secretsmanager put-secret-value \
    --secret-id "fis-chaos/webhook-proxy" \
    --region "$AWS_REGION" \
    --secret-string "$(cat <<EOJSON
{"endpoints":[{"space_id":"$PRIMARY_SPACE_ID","region":"$AGENT_REGION_PRIMARY","webhook_url":"$PRIMARY_WEBHOOK_URL","webhook_secret":"$PRIMARY_WEBHOOK_SECRET"},{"space_id":"$SECONDARY_SPACE_ID","region":"$AGENT_REGION_SECONDARY","webhook_url":"$SECONDARY_WEBHOOK_URL","webhook_secret":"$SECONDARY_WEBHOOK_SECRET"}]}
EOJSON
)" || echo "  ⚠️ Secret write failed (secret may not exist yet — re-run after terraform creates it)"

  # Export outputs
  terraform output -json experiment_template_ids > ../templates.json
  RESULTS_BUCKET=$(terraform output -raw results_bucket)
  GLOBAL_ENDPOINT_URL=$(terraform output -raw global_endpoint_url)
  GLOBAL_ENDPOINT_ID=$(terraform output -raw global_endpoint_id)
  cd ..

  echo "  ✓ FIS Layer deployed"
  echo "    10 experiment templates:"
  echo "      pod-kill, container-kill, network-delay, network-loss,"
  echo "      network-partition, cpu-stress, memory-stress, io-delay,"
  echo "      http-abort, dns-error"
  echo "    S3 bucket: $RESULTS_BUCKET"
  echo "    Global Endpoint: $GLOBAL_ENDPOINT_URL"
}

# ============================================================================
step8_create_devops_agent_spaces() {
  print_step "8" "Create DevOps Agent Spaces" "Creates NEW spaces (does NOT modify existing spaces). Primary in $AGENT_REGION_PRIMARY, Secondary in $AGENT_REGION_SECONDARY"

  # Skip if space IDs already provided
  if [ -n "${PRIMARY_SPACE_ID:-}" ] && [ -n "${SECONDARY_SPACE_ID:-}" ]; then
    echo "  ✓ Using provided space IDs:"
    echo "    Primary:   $PRIMARY_SPACE_ID ($AGENT_REGION_PRIMARY)"
    echo "    Secondary: $SECONDARY_SPACE_ID ($AGENT_REGION_SECONDARY)"
  else
    echo "  Using official AWS DevOps Agent Terraform sample for proper setup"
    echo "  (Creates IAM roles, operator app, account association automatically)"
    echo ""

    # Clone official sample if not present
    if [ ! -d "sample-aws-devops-agent-terraform" ]; then
      git clone https://github.com/aws-samples/sample-aws-devops-agent-terraform.git
    fi

    # Deploy primary space
    echo "  Deploying primaryspace in $AGENT_REGION_PRIMARY..."
    cd sample-aws-devops-agent-terraform
    cat > terraform.tfvars << TFEOF
agent_space_name        = "primaryspace"
agent_space_description = "FIS Chaos Testing - Primary Agent Space"
aws_region              = "$AGENT_REGION_PRIMARY"
TFEOF
    terraform init -input=false
    terraform workspace new "primary" 2>/dev/null || terraform workspace select "primary"
    terraform apply -auto-approve
    PRIMARY_SPACE_ID=$(terraform output -raw agent_space_id)
    echo "  ✓ primaryspace: $PRIMARY_SPACE_ID"

    # Deploy secondary space
    echo "  Deploying secondaryspace in $AGENT_REGION_SECONDARY..."
    cat > terraform.tfvars << TFEOF
agent_space_name        = "secondaryspace"
agent_space_description = "FIS Chaos Testing - DR Agent Space"
aws_region              = "$AGENT_REGION_SECONDARY"
TFEOF
    terraform workspace new "secondary" 2>/dev/null || terraform workspace select "secondary"
    terraform apply -auto-approve
    SECONDARY_SPACE_ID=$(terraform output -raw agent_space_id)
    echo "  ✓ secondaryspace: $SECONDARY_SPACE_ID"

    cd ..
    echo "  ✓ Both spaces deployed with IAM roles, operator app, and account association"
  fi
  echo "  primaryspace:   $PRIMARY_SPACE_ID ($AGENT_REGION_PRIMARY)"
  echo "  secondaryspace: $SECONDARY_SPACE_ID ($AGENT_REGION_SECONDARY)"

  # Grant EKS access to both agent roles
  echo "  Granting EKS access and S3 read to agent roles..."
  BUCKET_NAME="fis-chaos-results-$ACCOUNT_ID"
  for REGION_SPACE in "$AGENT_REGION_PRIMARY:$PRIMARY_SPACE_ID" "$AGENT_REGION_SECONDARY:$SECONDARY_SPACE_ID"; do
    SPACE_REGION="${REGION_SPACE%%:*}"
    SPACE_ID="${REGION_SPACE##*:}"
    [ -z "$SPACE_ID" ] && continue
    # The agent role ARN follows a pattern based on space ID
    ROLE_ARN=$(.venv/bin/python3.12 -c "
import boto3
client = boto3.client('devops-agent', region_name='$SPACE_REGION')
resp = client.list_associations(agentSpaceId='$SPACE_ID')
for a in resp.get('associations', []):
    cfg = a.get('configuration', {}).get('aws', {})
    if cfg.get('assumableRoleArn'):
        print(cfg['assumableRoleArn'])
        break
" 2>/dev/null || echo "")
    if [ -n "$ROLE_ARN" ]; then
      ROLE_NAME=$(echo "$ROLE_ARN" | awk -F'/' '{print $NF}')
      aws eks create-access-entry \
        --cluster-name $CLUSTER_NAME \
        --principal-arn "$ROLE_ARN" \
        --type STANDARD \
        --kubernetes-groups devops-agent \
        --region $AWS_REGION 2>/dev/null || true
      echo "    ✓ EKS access granted for $ROLE_NAME"

      # Grant S3 read for investigation history skill
      aws iam put-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-name fis-chaos-s3-read \
        --policy-document "{
          \"Version\": \"2012-10-17\",
          \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Action\": [\"s3:GetObject\", \"s3:ListBucket\"],
            \"Resource\": [
              \"arn:aws:s3:::$BUCKET_NAME\",
              \"arn:aws:s3:::$BUCKET_NAME/*\"
            ]
          }]
        }" 2>/dev/null || true
      echo "    ✓ S3 read granted for $ROLE_NAME → $BUCKET_NAME"
    fi
  done

  # Generate webhooks — skip if already provided as env vars
  if [ -n "${PRIMARY_WEBHOOK_URL:-}" ] && [ -n "${PRIMARY_WEBHOOK_SECRET:-}" ] && \
     [ -n "${SECONDARY_WEBHOOK_URL:-}" ] && [ -n "${SECONDARY_WEBHOOK_SECRET:-}" ]; then
    echo "  ✓ Webhook URLs/secrets provided via environment variables, skipping prompts"
  else
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║  MANUAL STEP: Generate webhooks in the AWS Console             ║"
    echo "  ║                                                                ║"
    echo "  ║  1. Open: https://${PRIMARY_SPACE_ID}.aidevops.global.app.aws  ║"
    echo "  ║     → Capabilities → Webhook → Generate                       ║"
    echo "  ║                                                                ║"
    echo "  ║  2. Open: https://${SECONDARY_SPACE_ID}.aidevops.global.app.aws║"
    echo "  ║     → Capabilities → Webhook → Generate                       ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Loop until valid primary webhook is provided
    while true; do
      echo "  Enter primaryspace ($AGENT_REGION_PRIMARY) webhook URL (or 'wait' to pause):"
      read -r PRIMARY_WEBHOOK_URL
      if [ "$PRIMARY_WEBHOOK_URL" = "wait" ]; then
        echo "  Waiting 30s... (generate webhook in console, then press Enter)"
        sleep 30
        continue
      fi
      if [[ "$PRIMARY_WEBHOOK_URL" == https://event-ai.* ]]; then
        break
      fi
      echo "  ⚠ Invalid URL. Expected format: https://event-ai.<region>.api.aws/webhook/generic/<id>"
    done
    echo "  Enter primaryspace ($AGENT_REGION_PRIMARY) webhook secret:"
    read -rs PRIMARY_WEBHOOK_SECRET
    echo ""

    # Loop until valid secondary webhook is provided
    while true; do
      echo "  Enter secondaryspace ($AGENT_REGION_SECONDARY) webhook URL (or 'wait' to pause):"
      read -r SECONDARY_WEBHOOK_URL
      if [ "$SECONDARY_WEBHOOK_URL" = "wait" ]; then
        echo "  Waiting 30s..."
        sleep 30
        continue
      fi
      if [[ "$SECONDARY_WEBHOOK_URL" == https://event-ai.* ]]; then
        break
      fi
      echo "  ⚠ Invalid URL. Expected format: https://event-ai.<region>.api.aws/webhook/generic/<id>"
    done
    echo "  Enter secondaryspace ($AGENT_REGION_SECONDARY) webhook secret:"
    read -rs SECONDARY_WEBHOOK_SECRET
  fi
  echo ""

  # Resolve space IDs from webhook URLs if not already set
  if [ -z "${PRIMARY_SPACE_ID:-}" ] || [ -z "${SECONDARY_SPACE_ID:-}" ]; then
    echo "  Resolving space IDs from webhook URLs..."
    RESOLVED=$(.venv/bin/python3.12 -c "
import boto3, json, sys

results = {}
for label, region, url in [('primary', '$AGENT_REGION_PRIMARY', '$PRIMARY_WEBHOOK_URL'), ('secondary', '$AGENT_REGION_SECONDARY', '$SECONDARY_WEBHOOK_URL')]:
    if not url:
        continue
    # Extract webhook ID from URL: https://event-ai.<region>.api.aws/webhook/generic/<webhook-id>
    target_webhook_id = url.rstrip('/').split('/')[-1]
    client = boto3.client('devops-agent', region_name=region)
    spaces = client.list_agent_spaces().get('agentSpaces', [])
    for space in spaces:
        try:
            webhooks = client.list_webhooks(agentSpaceId=space['agentSpaceId']).get('webhooks', [])
            for wh in webhooks:
                if wh.get('webhookId') == target_webhook_id or wh.get('url', '') == url:
                    results[label] = space['agentSpaceId']
                    break
        except Exception:
            pass
        if label in results:
            break
    if label not in results:
        print(f'WARNING: No space found owning webhook URL in {region}: {url}', file=sys.stderr)
print(json.dumps(results))
" 2>/dev/null)
    if [ -n "$RESOLVED" ]; then
      RESOLVED_PRIMARY=$(echo "$RESOLVED" | .venv/bin/python3.12 -c "import json,sys; print(json.load(sys.stdin).get('primary',''))")
      RESOLVED_SECONDARY=$(echo "$RESOLVED" | .venv/bin/python3.12 -c "import json,sys; print(json.load(sys.stdin).get('secondary',''))")
      [ -n "$RESOLVED_PRIMARY" ] && PRIMARY_SPACE_ID="$RESOLVED_PRIMARY"
      [ -n "$RESOLVED_SECONDARY" ] && SECONDARY_SPACE_ID="$RESOLVED_SECONDARY"
      echo "    Primary space:   $PRIMARY_SPACE_ID"
      echo "    Secondary space: $SECONDARY_SPACE_ID"
    fi
  fi

  echo "  ✓ Both spaces configured"
  echo "    primaryspace:   $PRIMARY_SPACE_ID in $AGENT_REGION_PRIMARY"
  echo "    secondaryspace: $SECONDARY_SPACE_ID in $AGENT_REGION_SECONDARY"

  # Tag both spaces with app=devopsagent (required for destroy.sh cleanup)
  .venv/bin/python3.12 -c "
import boto3
account = '$ACCOUNT_ID'
for region, space_id in [('$AGENT_REGION_PRIMARY', '$PRIMARY_SPACE_ID'), ('$AGENT_REGION_SECONDARY', '$SECONDARY_SPACE_ID')]:
    if not space_id:
        continue
    client = boto3.client('devops-agent', region_name=region)
    try:
        client.tag_resource(
            resourceArn=f'arn:aws:aidevops:{region}:{account}:agentspace/{space_id}',
            tags={'app': 'devopsagent'}
        )
        print(f'    ✓ Tagged {space_id} in {region}')
    except Exception as e:
        print(f'    ⚠ Tagging skipped for {space_id}: {e}')
"
  echo "  ✓ Both spaces tagged (app=devopsagent)"

  # Associate AWS account with both spaces
  echo "  Associating AWS account $ACCOUNT_ID with both spaces..."
  .venv/bin/python3.12 -c "
import boto3
for region, space_id in [('$AGENT_REGION_PRIMARY', '$PRIMARY_SPACE_ID'), ('$AGENT_REGION_SECONDARY', '$SECONDARY_SPACE_ID')]:
    client = boto3.client('devops-agent', region_name=region)
    try:
        client.associate_service(
            agentSpaceId=space_id,
            serviceId='aws',
            configuration={'aws': {'accountId': '$ACCOUNT_ID', 'accountType': 'monitor'}}
        )
        print(f'    ✓ {region}: account $ACCOUNT_ID associated')
    except Exception as e:
        if 'already' in str(e).lower() or 'conflict' in str(e).lower():
            print(f'    ✓ {region}: already associated')
        else:
            print(f'    ⚠ {region}: {e}')
"
}

# ============================================================================
step9_configure_skills() {
  print_step "10" "Configure Skills on Both Agent Spaces" "Enables shared investigation history via S3 — both spaces read prior RCAs for faster diagnosis"

  SKILL_TEXT="${SKILL_DESCRIPTION//BUCKET_PLACEHOLDER/$RESULTS_BUCKET}"

  echo "  Skill configured for both spaces:"
  echo "    Name: historical-investigation-results"
  echo "    Bucket: $RESULTS_BUCKET"
  echo ""
  echo "  ⚠️  MANUAL STEP: Add this skill to BOTH agent spaces via Console:"
  echo "    Agent Space → Skills → Add skill"
  echo "    Name: historical-investigation-results"
  echo "    Agent Type: Incident RCA, Incident Mitigation"
  echo "    Description (paste this):"
  echo ""
  echo "  $SKILL_TEXT"
  echo ""
}

# ============================================================================
step10_setup_python() {
  print_step "7" "Setup Python Environment" "Orchestrator needs boto3 for AWS API calls"
  python3.12 -m venv .venv
  source .venv/bin/activate
  pip install -q --upgrade pip
  pip install -q boto3 requests pip-system-certs awscrt
  pip install -q 'aws-devops-agent-acp @ git+https://github.com/aws-samples/sample-aws-devops-agent-acp-mcp.git'
  echo "  ✓ Python venv created with boto3"
}

# ============================================================================
step11_write_env() {
  print_step "11" "Write .env Configuration" "All runtime config in one file"
  cat > .env << EOF
export AWS_PROFILE=$AWS_PROFILE
export AGENT_SPACE_ID=$PRIMARY_SPACE_ID
export ENDPOINT_ID=$(cd terraform && terraform output -raw global_endpoint_id)
export AGENT_REGION=$AGENT_REGION_PRIMARY
export QUEUE_URL=$(cd terraform && terraform output -raw primary_agent_events_queue_url)
export RESULTS_BUCKET=$RESULTS_BUCKET
export AWS_DEFAULT_REGION=$AWS_REGION
EOF
  echo "  ✓ .env written"
  cat .env
}

# ============================================================================
step12_verify() {
  print_step "12" "Verify Deployment" "Quick smoke test"
  echo "  Checking EKS..."
  kubectl get nodes --no-headers | awk '{print "    " $1 " → " $2}'
  echo "  Checking Chaos Mesh..."
  kubectl get pods -n chaos-mesh --no-headers | wc -l | xargs -I{} echo "    {} pods running"
  echo "  Checking app..."
  kubectl get pods -n app --no-headers | wc -l | xargs -I{} echo "    {} pods running"
  echo "  Checking FIS templates..."
  cat templates.json | python3.12 -c "import json,sys; d=json.load(sys.stdin); print(f'    {len(d)} templates: {\", \".join(d.keys())}')"
  echo ""
  echo "  ✓ Deployment complete!"
  echo ""
  echo "  Run experiments:"
  echo "    source .venv/bin/activate && source .env"
  echo "    python orchestrator.py --templates templates.json \\"
  echo "      --endpoint-id \"\$ENDPOINT_ID\" \\"
  echo "      --agent-space-id \"\$AGENT_SPACE_ID\" --queue-url \"\$QUEUE_URL\" \\"
  echo "      --bucket \"\$RESULTS_BUCKET\" --random --limit 3"
}

# ============================================================================
# MAIN
# ============================================================================
echo "============================================================"
echo "  FIS Chaos Testing + DevOps Agent — Full Deployment"
echo "  Deploys: EKS, Chaos Mesh, FIS (10 experiments),"
echo "  DevOps Agent (2 spaces), webhook proxy, scoring infra"
echo "============================================================"
echo ""

check_prereqs
step1_clone_eks_repo
step2_deploy_eks
step3_install_chaos_mesh
step4_deploy_sample_app
step5_enable_container_insights
step6_apply_rbac
step10_setup_python
step8_create_devops_agent_spaces
step7_deploy_fis_layer
step9_configure_skills
step11_write_env
step12_verify

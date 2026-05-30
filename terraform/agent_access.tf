# =============================================================================
# DevOps Agent EKS Access — dynamic role lookup
#
# Discovers agent IAM roles by trust policy region.
# If roles not found (spaces not yet created), entries are skipped.
# Re-run terraform apply after spaces are created to add access.
# =============================================================================

data "external" "agent_roles" {
  program = ["python3", "${path.module}/../scripts/resolve_agent_roles.py"]

  query = {
    primary_region   = var.primary_agent_region
    secondary_region = var.secondary_agent_region
  }
}

locals {
  primary_role_arn   = try(data.external.agent_roles.result.primary_role_arn, "")
  secondary_role_arn = try(data.external.agent_roles.result.secondary_role_arn, "")
}

resource "aws_eks_access_entry" "agent_primary" {
  count             = local.primary_role_arn != "" ? 1 : 0
  cluster_name      = var.cluster_name
  principal_arn     = local.primary_role_arn
  type              = "STANDARD"
  kubernetes_groups = ["devops-agent"]
}

resource "aws_eks_access_entry" "agent_secondary" {
  count             = local.secondary_role_arn != "" ? 1 : 0
  cluster_name      = var.cluster_name
  principal_arn     = local.secondary_role_arn
  type              = "STANDARD"
  kubernetes_groups = ["devops-agent"]
}

# 10 FIS experiment templates — each injects a Chaos Mesh CRD via
# aws:eks:inject-kubernetes-custom-resource

locals {
  cluster_arn  = data.aws_eks_cluster.cluster.arn
  log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
  fis_role_arn  = aws_iam_role.fis.arn

  experiments = jsondecode(file("${path.module}/../experiments.json")).experiments
}

resource "aws_fis_experiment_template" "chaos" {
  for_each = { for e in local.experiments : e.id => e }

  description = each.value.name
  role_arn    = local.fis_role_arn

  stop_condition {
    source = "none"
  }

  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = local.log_group_arn
    }
    log_schema_version = 2
  }

  target {
    name           = "Cluster-Target-1"
    resource_type  = "aws:eks:cluster"
    selection_mode = "ALL"
    resource_arns  = [local.cluster_arn]
  }

  action {
    name        = each.key
    action_id   = "aws:eks:inject-kubernetes-custom-resource"
    description = each.value.description
    target {
      key   = "Cluster"
      value = "Cluster-Target-1"
    }
    parameter {
      key   = "kubernetesApiVersion"
      value = each.value.api_version
    }
    parameter {
      key   = "kubernetesKind"
      value = each.value.chaos_kind
    }
    parameter {
      key   = "kubernetesNamespace"
      value = "chaos-mesh"
    }
    parameter {
      key   = "kubernetesSpec"
      value = jsonencode(each.value.spec)
    }
    parameter {
      key   = "maxDuration"
      value = each.value.duration
    }
  }

  tags = {
    ChaosExperiment = each.key
    GroundTruth     = each.value.ground_truth
    ExpectedAlarm   = each.value.expected_alarm
  }
}

# Output template IDs for the orchestrator script
output "experiment_template_ids" {
  value = { for k, v in aws_fis_experiment_template.chaos : k => v.id }
}

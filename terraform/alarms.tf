locals {
  ci_namespace = "ContainerInsights"
  ci_dims_ui = {
    ClusterName = var.cluster_name
    Namespace   = var.app_namespace
    Service     = "ui"
  }
  ci_dims_checkout = {
    ClusterName = var.cluster_name
    Namespace   = var.app_namespace
    Service     = "checkout"
  }
  ci_dims_catalog = {
    ClusterName = var.cluster_name
    Namespace   = var.app_namespace
    Service     = "catalog"
  }
}

resource "aws_cloudwatch_metric_alarm" "pod_restart" {
  alarm_name          = "chaos-pod-restart"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_number_of_container_restarts"
  namespace           = local.ci_namespace
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Pod container restart detected"
  dimensions          = local.ci_dims_ui
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "chaos-high-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_interface_network_rx_dropped"
  namespace           = local.ci_namespace
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Network errors detected"
  dimensions          = local.ci_dims_ui
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "chaos-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_interface_network_rx_dropped"
  namespace           = local.ci_namespace
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Network anomaly detected"
  dimensions          = local.ci_dims_catalog
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "chaos-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_cpu_utilization"
  namespace           = local.ci_namespace
  period              = 60
  statistic           = "Maximum"
  threshold           = 80
  alarm_description   = "High pod CPU utilization"
  dimensions          = local.ci_dims_ui
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "high_memory" {
  alarm_name          = "chaos-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_memory_utilization"
  namespace           = local.ci_namespace
  period              = 60
  statistic           = "Maximum"
  threshold           = 80
  alarm_description   = "High pod memory utilization"
  dimensions          = local.ci_dims_ui
  treat_missing_data  = "notBreaching"
}

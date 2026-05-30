# =============================================================================
# EventBridge Global Endpoint — infrastructure-level failover
#
# Single entry URL → routes to healthy region → SQS buffer → Lambda forwarder → agent
# Failover driven by CloudWatch alarm (forwarder health metric) → Route53 health check
# =============================================================================

# --- Custom EventBridge buses (Global Endpoint requires custom, not default) ---

resource "aws_cloudwatch_event_bus" "global_primary" {
  provider = aws.us_east_1
  name     = "fis-chaos-global-inbound"
}

resource "aws_cloudwatch_event_bus" "global_secondary" {
  provider = aws.secondary
  name     = "fis-chaos-global-inbound"
}

# --- Inbound SQS queues (14-day buffer) + DLQ per region ---

resource "aws_sqs_queue" "global_dlq_primary" {
  provider                  = aws.us_east_1
  name                      = "fis-chaos-global-inbound-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "global_inbound_primary" {
  provider                   = aws.us_east_1
  name                       = "fis-chaos-global-inbound"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 120
  receive_wait_time_seconds  = 20
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.global_dlq_primary.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "global_dlq_secondary" {
  provider                  = aws.secondary
  name                      = "fis-chaos-global-inbound-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "global_inbound_secondary" {
  provider                   = aws.secondary
  name                       = "fis-chaos-global-inbound"
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 120
  receive_wait_time_seconds  = 20
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.global_dlq_secondary.arn
    maxReceiveCount     = 3
  })
}

# --- EventBridge rules: bus → SQS ---

resource "aws_cloudwatch_event_rule" "global_to_sqs_primary" {
  provider       = aws.us_east_1
  name           = "fis-chaos-global-to-sqs"
  event_bus_name = aws_cloudwatch_event_bus.global_primary.name
  event_pattern  = jsonencode({ "source" = [{ "prefix" = "" }] })
}

resource "aws_cloudwatch_event_target" "global_to_sqs_primary" {
  provider       = aws.us_east_1
  rule           = aws_cloudwatch_event_rule.global_to_sqs_primary.name
  event_bus_name = aws_cloudwatch_event_bus.global_primary.name
  target_id      = "inbound-sqs"
  arn            = aws_sqs_queue.global_inbound_primary.arn
}

resource "aws_sqs_queue_policy" "global_inbound_primary" {
  provider  = aws.us_east_1
  queue_url = aws_sqs_queue.global_inbound_primary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.global_inbound_primary.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.global_to_sqs_primary.arn } }
    }]
  })
}

resource "aws_cloudwatch_event_rule" "global_to_sqs_secondary" {
  provider       = aws.secondary
  name           = "fis-chaos-global-to-sqs"
  event_bus_name = aws_cloudwatch_event_bus.global_secondary.name
  event_pattern  = jsonencode({ "source" = [{ "prefix" = "" }] })
}

resource "aws_cloudwatch_event_target" "global_to_sqs_secondary" {
  provider       = aws.secondary
  rule           = aws_cloudwatch_event_rule.global_to_sqs_secondary.name
  event_bus_name = aws_cloudwatch_event_bus.global_secondary.name
  target_id      = "inbound-sqs"
  arn            = aws_sqs_queue.global_inbound_secondary.arn
}

resource "aws_sqs_queue_policy" "global_inbound_secondary" {
  provider  = aws.secondary
  queue_url = aws_sqs_queue.global_inbound_secondary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.global_inbound_secondary.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.global_to_sqs_secondary.arn } }
    }]
  })
}

# --- CloudWatch Alarm (drives Route53 health check → Global Endpoint failover) ---

resource "aws_cloudwatch_metric_alarm" "global_endpoint_health" {
  provider            = aws.us_east_1
  alarm_name          = "fis-chaos-global-endpoint-health"
  namespace           = "FISChaos"
  metric_name         = "EndpointHealth"
  dimensions          = { Region = "primary" }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Primary forwarder unhealthy — triggers Global Endpoint failover"
}

# --- Route53 Health Check (watches the CloudWatch alarm) ---

# Route53 needs a provider without default_tags (SCP blocks route53:ChangeTagsForResource)
provider "aws" {
  alias  = "no_tags"
  region = var.region
}

resource "aws_route53_health_check" "global_endpoint" {
  provider                        = aws.no_tags
  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.global_endpoint_health.alarm_name
  cloudwatch_alarm_region         = var.primary_agent_region
  insufficient_data_health_status = "Healthy"
}

# --- EventBridge Global Endpoint ---

resource "aws_cloudwatch_event_endpoint" "global" {
  name = "fis-chaos-global"

  event_bus {
    event_bus_arn = aws_cloudwatch_event_bus.global_primary.arn
  }
  event_bus {
    event_bus_arn = aws_cloudwatch_event_bus.global_secondary.arn
  }

  replication_config {
    state = "DISABLED"
  }

  routing_config {
    failover_config {
      primary {
        health_check = aws_route53_health_check.global_endpoint.arn
      }
      secondary {
        route = var.secondary_agent_region
      }
    }
  }
}

# --- Secrets Manager replication (so secondary Lambda can read locally) ---
# NOTE: replica block added to aws_secretsmanager_secret.webhook_proxy in secrets.tf

# --- Lambda forwarder (shared IAM role, deployed in both regions) ---

resource "aws_iam_role" "global_forwarder" {
  name = "fis-chaos-global-forwarder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "global_forwarder" {
  name = "fis-chaos-global-forwarder"
  role = aws_iam_role.global_forwarder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.webhook_proxy.arn,
          "arn:aws:secretsmanager:${var.secondary_agent_region}:${data.aws_caller_identity.current.account_id}:secret:fis-chaos/webhook-proxy-*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:SendMessage"]
        Resource = [
          aws_sqs_queue.global_inbound_primary.arn,
          aws_sqs_queue.global_inbound_secondary.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem", "dynamodb:Scan"]
        Resource = [
          aws_dynamodb_table.investigations.arn,
          "arn:aws:dynamodb:${var.secondary_agent_region}:${data.aws_caller_identity.current.account_id}:table/fis-chaos-investigations",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

data "archive_file" "global_forwarder" {
  type        = "zip"
  source_file = "${path.module}/../lambda/global_forwarder.py"
  output_path = "${path.module}/../lambda/global_forwarder.zip"
}

# Primary region forwarder
resource "aws_lambda_function" "global_forwarder_primary" {
  provider         = aws.us_east_1
  function_name    = "fis-chaos-global-forwarder"
  role             = aws_iam_role.global_forwarder.arn
  handler          = "global_forwarder.handler"
  runtime          = "python3.12"
  timeout          = 90
  filename         = data.archive_file.global_forwarder.output_path
  source_code_hash = data.archive_file.global_forwarder.output_base64sha256

  environment {
    variables = {
      SECRET_ID        = aws_secretsmanager_secret.webhook_proxy.name
      TARGET           = "primary"
      FAILOVER_QUEUE_URL = aws_sqs_queue.global_inbound_secondary.id
      FAILOVER_REGION  = var.secondary_agent_region
      TABLE_NAME       = aws_dynamodb_table.investigations.name
    }
  }
}

# Secondary region forwarder
resource "aws_lambda_function" "global_forwarder_secondary" {
  provider         = aws.secondary
  function_name    = "fis-chaos-global-forwarder"
  role             = aws_iam_role.global_forwarder.arn
  handler          = "global_forwarder.handler"
  runtime          = "python3.12"
  timeout          = 90
  filename         = data.archive_file.global_forwarder.output_path
  source_code_hash = data.archive_file.global_forwarder.output_base64sha256

  environment {
    variables = {
      SECRET_ID        = aws_secretsmanager_secret.webhook_proxy.name
      TARGET           = "secondary"
      FAILOVER_QUEUE_URL = aws_sqs_queue.global_inbound_primary.id
      FAILOVER_REGION  = var.primary_agent_region
      TABLE_NAME       = aws_dynamodb_table.investigations.name
    }
  }
}

# --- SQS → Lambda event source mappings ---

resource "aws_lambda_event_source_mapping" "global_primary" {
  provider                           = aws.us_east_1
  event_source_arn                   = aws_sqs_queue.global_inbound_primary.arn
  function_name                      = aws_lambda_function.global_forwarder_primary.arn
  batch_size                         = 1
  function_response_types            = ["ReportBatchItemFailures"]
  maximum_batching_window_in_seconds = 0
}

resource "aws_lambda_event_source_mapping" "global_secondary" {
  provider                           = aws.secondary
  event_source_arn                   = aws_sqs_queue.global_inbound_secondary.arn
  function_name                      = aws_lambda_function.global_forwarder_secondary.arn
  batch_size                         = 1
  function_response_types            = ["ReportBatchItemFailures"]
  maximum_batching_window_in_seconds = 0
}

# --- Outputs ---

output "global_endpoint_url" {
  value       = aws_cloudwatch_event_endpoint.global.endpoint_url
  description = "EventBridge Global Endpoint URL — single entry point for all external tools"
}

output "global_endpoint_id" {
  value       = regex("https://([^.]+\\.[^.]+)\\.endpoint\\.events\\.amazonaws\\.com", aws_cloudwatch_event_endpoint.global.endpoint_url)[0]
  description = "EndpointId for PutEvents API (subdomain only, e.g. abcde.veo)"
}

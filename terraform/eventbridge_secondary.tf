# EventBridge + SQS for the failover DevOps Agent space
# Mirrors primary (us-east-1) setup in the secondary region

provider "aws" {
  alias  = "secondary"
  region = var.secondary_agent_region
  default_tags {
    tags = {
      app = "devopsagent"
    }
  }
}

resource "aws_cloudwatch_log_group" "agent_events_secondary" {
  provider          = aws.secondary
  name              = "/fis-chaos/devops-agent-events"
  retention_in_days = 7
}

data "aws_iam_policy_document" "agent_events_log_policy_secondary" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.agent_events_secondary.arn}:*"]
  }
}

resource "aws_cloudwatch_log_resource_policy" "agent_events_secondary" {
  provider        = aws.secondary
  policy_name     = "fis-chaos-agent-events"
  policy_document = data.aws_iam_policy_document.agent_events_log_policy_secondary.json
}

resource "aws_cloudwatch_event_rule" "agent_investigation_secondary" {
  provider    = aws.secondary
  name        = "fis-chaos-agent-investigation"
  description = "Capture DevOps Agent investigation lifecycle events (failover region)"
  event_pattern = jsonencode({
    source      = ["aws.aidevops"]
    detail-type = [
      "Investigation Created",
      "Investigation In Progress",
      "Investigation Completed",
      "Investigation Failed",
      "Investigation Timed Out",
      "Investigation Cancelled",
      "Investigation Linked",
      "Mitigation In Progress",
      "Mitigation Completed",
      "Mitigation Failed",
      "Mitigation Timed Out",
      "Mitigation Cancelled"
    ]
  })
}

resource "aws_cloudwatch_event_target" "agent_to_logs_secondary" {
  provider  = aws.secondary
  rule      = aws_cloudwatch_event_rule.agent_investigation_secondary.name
  target_id = "agent-events-to-logs"
  arn       = aws_cloudwatch_log_group.agent_events_secondary.arn
}

resource "aws_sqs_queue" "agent_events_secondary" {
  provider                   = aws.secondary
  name                       = "fis-chaos-agent-events"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
}

resource "aws_sqs_queue_policy" "agent_events_secondary" {
  provider  = aws.secondary
  queue_url = aws_sqs_queue.agent_events_secondary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.agent_events_secondary.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.agent_investigation_secondary.arn }
      }
    }]
  })
}

resource "aws_cloudwatch_event_target" "agent_to_sqs_secondary" {
  provider  = aws.secondary
  rule      = aws_cloudwatch_event_rule.agent_investigation_secondary.name
  target_id = "agent-events-to-sqs"
  arn       = aws_sqs_queue.agent_events_secondary.arn
}

output "secondary_agent_events_queue_url" {
  value = aws_sqs_queue.agent_events_secondary.id
}

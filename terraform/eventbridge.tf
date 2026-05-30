# EventBridge rule to capture DevOps Agent investigation events
# Agent publishes to primary agent region (where the primary space lives)

provider "aws" {
  alias  = "us_east_1"
  region = var.primary_agent_region
  default_tags {
    tags = {
      app = "devopsagent"
    }
  }
}

resource "aws_cloudwatch_log_group" "agent_events" {
  provider          = aws.us_east_1
  name              = "/fis-chaos/devops-agent-events"
  retention_in_days = 7
}

data "aws_iam_policy_document" "agent_events_log_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.agent_events.arn}:*"]
  }
}

resource "aws_cloudwatch_log_resource_policy" "agent_events" {
  provider        = aws.us_east_1
  policy_name     = "fis-chaos-agent-events"
  policy_document = data.aws_iam_policy_document.agent_events_log_policy.json
}

resource "aws_cloudwatch_event_rule" "agent_investigation" {
  provider    = aws.us_east_1
  name        = "fis-chaos-agent-investigation"
  description = "Capture DevOps Agent investigation lifecycle events"
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

resource "aws_cloudwatch_event_target" "agent_to_logs" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.agent_investigation.name
  target_id = "agent-events-to-logs"
  arn       = aws_cloudwatch_log_group.agent_events.arn
}

# --- SQS queue for event-driven investigation results ---

resource "aws_sqs_queue" "agent_events" {
  provider                   = aws.us_east_1
  name                       = "fis-chaos-agent-events"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20 # long polling
}

resource "aws_sqs_queue_policy" "agent_events" {
  provider  = aws.us_east_1
  queue_url = aws_sqs_queue.agent_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.agent_events.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.agent_investigation.arn }
      }
    }]
  })
}

resource "aws_cloudwatch_event_target" "agent_to_sqs" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.agent_investigation.name
  target_id = "agent-events-to-sqs"
  arn       = aws_sqs_queue.agent_events.arn
}

output "primary_agent_events_queue_url" {
  value = aws_sqs_queue.agent_events.id
}

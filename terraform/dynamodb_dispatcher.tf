# =============================================================================
# DynamoDB Global Table + Dispatcher Lambda
#
# Dispatcher reads agent lifecycle events from SQS and writes to DynamoDB.
# Orchestrator polls DynamoDB by incident_id — no direct SQS consumption needed.
# =============================================================================

# --- DynamoDB Global Table ---

resource "aws_dynamodb_table" "investigations" {
  name             = "fis-chaos-investigations"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "incident_id"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "incident_id"
    type = "S"
  }

  attribute {
    name = "task_id"
    type = "S"
  }

  global_secondary_index {
    name            = "task_id-index"
    hash_key        = "task_id"
    projection_type = "ALL"
  }

  replica {
    region_name = var.secondary_agent_region
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

# --- IAM Role (shared by both region's Lambdas) ---

resource "aws_iam_role" "dispatcher" {
  name = "fis-chaos-dispatcher"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "dispatcher" {
  name = "fis-chaos-dispatcher"
  role = aws_iam_role.dispatcher.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:Query"]
        Resource = [
          aws_dynamodb_table.investigations.arn,
          "${aws_dynamodb_table.investigations.arn}/index/*",
          "arn:aws:dynamodb:${var.secondary_agent_region}:${data.aws_caller_identity.current.account_id}:table/fis-chaos-investigations",
          "arn:aws:dynamodb:${var.secondary_agent_region}:${data.aws_caller_identity.current.account_id}:table/fis-chaos-investigations/index/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["aidevops:ListBacklogTasks"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [
          aws_sqs_queue.agent_events.arn,
          aws_sqs_queue.agent_events_secondary.arn,
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

# --- Lambda zip (pre-built with boto3 bundled: cd lambda && ./build_dispatcher.sh) ---

locals {
  dispatcher_zip = "${path.module}/../lambda/dispatcher_pkg.zip"
}

# --- Primary region dispatcher ---

resource "aws_lambda_function" "dispatcher_primary" {
  provider         = aws.us_east_1
  function_name    = "fis-chaos-dispatcher"
  role             = aws_iam_role.dispatcher.arn
  handler          = "dispatcher.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = local.dispatcher_zip
  source_code_hash = filebase64sha256(local.dispatcher_zip)

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.investigations.name
    }
  }
}

resource "aws_lambda_event_source_mapping" "dispatcher_primary" {
  provider                           = aws.us_east_1
  event_source_arn                   = aws_sqs_queue.agent_events.arn
  function_name                      = aws_lambda_function.dispatcher_primary.arn
  batch_size                         = 10
  function_response_types            = ["ReportBatchItemFailures"]
  maximum_batching_window_in_seconds = 5
}

# --- Secondary region dispatcher ---

resource "aws_lambda_function" "dispatcher_secondary" {
  provider         = aws.secondary
  function_name    = "fis-chaos-dispatcher"
  role             = aws_iam_role.dispatcher.arn
  handler          = "dispatcher.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = local.dispatcher_zip
  source_code_hash = filebase64sha256(local.dispatcher_zip)

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.investigations.name
    }
  }
}

resource "aws_lambda_event_source_mapping" "dispatcher_secondary" {
  provider                           = aws.secondary
  event_source_arn                   = aws_sqs_queue.agent_events_secondary.arn
  function_name                      = aws_lambda_function.dispatcher_secondary.arn
  batch_size                         = 10
  function_response_types            = ["ReportBatchItemFailures"]
  maximum_batching_window_in_seconds = 5
}

# --- Output ---

output "investigations_table_name" {
  value = aws_dynamodb_table.investigations.name
}

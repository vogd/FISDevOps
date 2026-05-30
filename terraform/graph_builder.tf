# Graph Builder Lambda — assembles incident graph HTML from per-investigation JSON files
# Runs every 5 minutes, reads graph/*.json, writes graph/index.html to S3

data "archive_file" "graph_builder" {
  type        = "zip"
  source_file = "${path.module}/../lambda/graph_builder.py"
  output_path = "${path.module}/../lambda/graph_builder.zip"
}

resource "aws_iam_role" "graph_builder" {
  name = "fis-chaos-graph-builder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "graph_builder" {
  name = "fis-chaos-graph-builder"
  role = aws_iam_role.graph_builder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket", "s3:PutObject"]
        Resource = [
          aws_s3_bucket.results.arn,
          "${aws_s3_bucket.results.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = aws_dynamodb_table.investigations.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.graph_builder_trigger.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "graph_builder" {
  function_name    = "fis-chaos-graph-builder"
  role             = aws_iam_role.graph_builder.arn
  handler          = "graph_builder.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.graph_builder.output_path
  source_code_hash = data.archive_file.graph_builder.output_base64sha256

  environment {
    variables = {
      BUCKET     = aws_s3_bucket.results.id
      TABLE_NAME = aws_dynamodb_table.investigations.name
    }
  }
}

resource "aws_cloudwatch_event_rule" "graph_builder" {
  name                = "fis-chaos-graph-builder"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "graph_builder" {
  rule      = aws_cloudwatch_event_rule.graph_builder.name
  target_id = "graph-builder-lambda"
  arn       = aws_lambda_function.graph_builder.arn
}

resource "aws_lambda_permission" "graph_builder_eb" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.graph_builder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.graph_builder.arn
}

# --- S3 event → SQS (60s batch) → graph_builder for near-real-time updates ---

resource "aws_sqs_queue" "graph_builder_trigger" {
  name                       = "fis-chaos-graph-builder-trigger"
  message_retention_seconds  = 300
  visibility_timeout_seconds = 120
}

resource "aws_sqs_queue_policy" "graph_builder_trigger" {
  queue_url = aws_sqs_queue.graph_builder_trigger.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.graph_builder_trigger.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_s3_bucket.results.arn } }
    }]
  })
}

resource "aws_s3_bucket_notification" "graph_trigger" {
  bucket = aws_s3_bucket.results.id

  queue {
    queue_arn     = aws_sqs_queue.graph_builder_trigger.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "graph/"
    filter_suffix = ".json"
  }
}

resource "aws_lambda_event_source_mapping" "graph_builder_sqs" {
  event_source_arn                   = aws_sqs_queue.graph_builder_trigger.arn
  function_name                      = aws_lambda_function.graph_builder.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 60
}

resource "aws_lambda_permission" "graph_builder_sqs" {
  statement_id  = "AllowSQS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.graph_builder.function_name
  principal     = "sqs.amazonaws.com"
  source_arn    = aws_sqs_queue.graph_builder_trigger.arn
}

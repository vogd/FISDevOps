# RCA Writer Lambda — auto-persists investigation/mitigation results to S3
# Deployed in BOTH regions, triggered by EventBridge completion events

# --- Primary (us-east-1) ---

resource "aws_iam_role" "rca_writer" {
  provider = aws.us_east_1
  name     = "fis-chaos-rca-writer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rca_writer" {
  provider = aws.us_east_1
  name     = "fis-chaos-rca-writer"
  role     = aws_iam_role.rca_writer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.results.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["aidevops:ListJournalRecords"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:GetItem"]
        Resource = [
          aws_dynamodb_table.investigations.arn,
          "${aws_dynamodb_table.investigations.arn}/index/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.primary_agent_region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

data "archive_file" "rca_writer" {
  type        = "zip"
  source_file = "${path.module}/../lambda/rca_writer.py"
  output_path = "${path.module}/../lambda/rca_writer.zip"
}

resource "aws_lambda_function" "rca_writer" {
  provider         = aws.us_east_1
  function_name    = "fis-chaos-rca-writer"
  role             = aws_iam_role.rca_writer.arn
  handler          = "rca_writer.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.rca_writer.output_path
  source_code_hash = data.archive_file.rca_writer.output_base64sha256

  environment {
    variables = {
      BUCKET     = aws_s3_bucket.results.id
      TABLE_NAME = aws_dynamodb_table.investigations.name
    }
  }
}

resource "aws_lambda_permission" "rca_writer_eb" {
  provider      = aws.us_east_1
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rca_writer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.agent_investigation.arn
}

resource "aws_cloudwatch_event_target" "agent_to_rca_writer" {
  provider  = aws.us_east_1
  rule      = aws_cloudwatch_event_rule.agent_investigation.name
  target_id = "rca-writer"
  arn       = aws_lambda_function.rca_writer.arn
}

# --- Secondary (us-west-2) ---

resource "aws_iam_role" "rca_writer_secondary" {
  provider = aws.secondary
  name     = "fis-chaos-rca-writer-secondary"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rca_writer_secondary" {
  provider = aws.secondary
  name     = "fis-chaos-rca-writer"
  role     = aws_iam_role.rca_writer_secondary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.results.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["aidevops:ListJournalRecords"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [
          "arn:aws:dynamodb:${var.secondary_agent_region}:${data.aws_caller_identity.current.account_id}:table/fis-chaos-investigations",
          "arn:aws:dynamodb:${var.secondary_agent_region}:${data.aws_caller_identity.current.account_id}:table/fis-chaos-investigations/index/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.secondary_agent_region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "rca_writer_secondary" {
  provider         = aws.secondary
  function_name    = "fis-chaos-rca-writer"
  role             = aws_iam_role.rca_writer_secondary.arn
  handler          = "rca_writer.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.rca_writer.output_path
  source_code_hash = data.archive_file.rca_writer.output_base64sha256

  environment {
    variables = {
      BUCKET     = aws_s3_bucket.results.id
      TABLE_NAME = aws_dynamodb_table.investigations.name
    }
  }
}

resource "aws_lambda_permission" "rca_writer_eb_secondary" {
  provider      = aws.secondary
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rca_writer_secondary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.agent_investigation_secondary.arn
}

resource "aws_cloudwatch_event_target" "agent_to_rca_writer_secondary" {
  provider  = aws.secondary
  rule      = aws_cloudwatch_event_rule.agent_investigation_secondary.name
  target_id = "rca-writer"
  arn       = aws_lambda_function.rca_writer_secondary.arn
}

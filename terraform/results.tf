resource "aws_s3_bucket" "results" {
  bucket = "fis-chaos-results-${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_role" "scorer" {
  name = "fis-chaos-scorer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scorer" {
  name = "fis-chaos-scorer"
  role = aws_iam_role.scorer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.region}::foundation-model/us.anthropic.claude-sonnet-4-6"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

data "archive_file" "scorer" {
  type        = "zip"
  source_file = "${path.module}/../lambda/scorer.py"
  output_path = "${path.module}/../lambda/scorer.zip"
}

resource "aws_lambda_function" "scorer" {
  function_name    = "fis-chaos-scorer"
  role             = aws_iam_role.scorer.arn
  handler          = "scorer.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.scorer.output_path
  source_code_hash = data.archive_file.scorer.output_base64sha256

  environment {
    variables = {
      BUCKET   = aws_s3_bucket.results.id
      MODEL_ID = "us.anthropic.claude-sonnet-4-6"
    }
  }
}

output "results_bucket" {
  value = aws_s3_bucket.results.id
}

output "scorer_function_name" {
  value = aws_lambda_function.scorer.function_name
}

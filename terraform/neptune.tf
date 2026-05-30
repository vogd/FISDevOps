# =============================================================================
# Neptune Graph DB — cross-workspace dependency visualization
#
# DynamoDB Streams → Neptune Feeder Lambda → Neptune Serverless
# Enables: blast radius queries, cross-region correlation, dependency graphs
# =============================================================================

# --- Neptune Serverless Cluster ---

resource "aws_neptune_cluster" "investigations" {
  cluster_identifier                  = "fis-chaos-investigations"
  engine                              = "neptune"
  serverless_v2_scaling_configuration {
    min_capacity = 10.0
    max_capacity = 16.0
  }
  vpc_security_group_ids = [aws_security_group.neptune.id]
  neptune_subnet_group_name = aws_neptune_subnet_group.main.name
  skip_final_snapshot    = true
  iam_database_authentication_enabled = true
  apply_immediately      = true
}

resource "aws_neptune_cluster_instance" "serverless" {
  cluster_identifier = aws_neptune_cluster.investigations.id
  instance_class     = "db.serverless"
  engine             = "neptune"
}

# --- Networking (uses default VPC + NAT Gateway for outbound) ---

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# NAT Gateway — must be in a PUBLIC subnet (default subnets have IGW route)
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = tolist(data.aws_subnets.default.ids)[0]  # public subnet (has IGW)
}

# Private subnet for Lambdas (routes through NAT, not IGW)
resource "aws_subnet" "lambda_private" {
  vpc_id            = data.aws_vpc.default.id
  cidr_block        = cidrsubnet(data.aws_vpc.default.cidr_block, 8, 200)
  availability_zone = "${var.region}a"

  tags = { Name = "fis-chaos-lambda-private" }
}

resource "aws_subnet" "lambda_private_b" {
  vpc_id            = data.aws_vpc.default.id
  cidr_block        = cidrsubnet(data.aws_vpc.default.cidr_block, 8, 201)
  availability_zone = "${var.region}b"

  tags = { Name = "fis-chaos-lambda-private-b" }
}

resource "aws_route_table" "lambda_private" {
  vpc_id = data.aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "fis-chaos-lambda-private" }
}

resource "aws_route_table_association" "lambda_private_a" {
  subnet_id      = aws_subnet.lambda_private.id
  route_table_id = aws_route_table.lambda_private.id
}

resource "aws_route_table_association" "lambda_private_b" {
  subnet_id      = aws_subnet.lambda_private_b.id
  route_table_id = aws_route_table.lambda_private.id
}

locals {
  lambda_subnet_ids = [aws_subnet.lambda_private.id, aws_subnet.lambda_private_b.id]
}

resource "aws_neptune_subnet_group" "main" {
  name       = "fis-chaos-neptune"
  subnet_ids = concat(data.aws_subnets.default.ids, local.lambda_subnet_ids)
}

resource "aws_security_group" "neptune" {
  name   = "fis-chaos-neptune"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = 8182
    to_port         = 8182
    protocol        = "tcp"
    security_groups = [aws_security_group.neptune_feeder.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "neptune_feeder" {
  name   = "fis-chaos-neptune-feeder"
  vpc_id = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Neptune Feeder Lambda ---

resource "aws_iam_role" "neptune_feeder" {
  name = "fis-chaos-neptune-feeder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "neptune_feeder" {
  name = "fis-chaos-neptune-feeder"
  role = aws_iam_role.neptune_feeder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams",
        ]
        Resource = [
          "${aws_dynamodb_table.investigations.arn}/stream/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["neptune-db:*"]
        Resource = "arn:aws:neptune-db:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_neptune_cluster.investigations.cluster_resource_id}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = "*"
      },
    ]
  })
}

data "archive_file" "neptune_feeder" {
  type        = "zip"
  output_path = "${path.module}/../lambda/neptune_feeder.zip"
  source {
    content  = file("${path.module}/../lambda/neptune_feeder.py")
    filename = "neptune_feeder.py"
  }
  source {
    content  = file("${path.module}/../lambda/neptune_client.py")
    filename = "neptune_client.py"
  }
}

resource "aws_lambda_function" "neptune_feeder" {
  function_name    = "fis-chaos-neptune-feeder"
  role             = aws_iam_role.neptune_feeder.arn
  handler          = "neptune_feeder.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.neptune_feeder.output_path
  source_code_hash = data.archive_file.neptune_feeder.output_base64sha256

  vpc_config {
    subnet_ids         = local.lambda_subnet_ids
    security_group_ids = [aws_security_group.neptune_feeder.id]
  }

  environment {
    variables = {
      NEPTUNE_ENDPOINT = aws_neptune_cluster.investigations.endpoint
      NEPTUNE_PORT     = "8182"
    }
  }
}

# --- DynamoDB Streams → Lambda trigger ---

resource "aws_lambda_event_source_mapping" "neptune_feeder" {
  event_source_arn                   = aws_dynamodb_table.investigations.stream_arn
  function_name                      = aws_lambda_function.neptune_feeder.arn
  starting_position                  = "LATEST"
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

# --- Outputs ---

output "neptune_endpoint" {
  value       = aws_neptune_cluster.investigations.endpoint
  description = "Neptune cluster endpoint for Gremlin queries"
}

output "neptune_reader_endpoint" {
  value       = aws_neptune_cluster.investigations.reader_endpoint
  description = "Neptune reader endpoint for read-heavy queries"
}

# =============================================================================
# Config → Neptune Sync — periodic infrastructure graph sync
# =============================================================================

resource "aws_iam_role" "config_sync" {
  name = "fis-chaos-config-sync"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "config_sync" {
  name = "fis-chaos-config-sync"
  role = aws_iam_role.config_sync.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "config:ListDiscoveredResources",
          "config:SelectResourceConfig",
          "config:BatchGetResourceConfig",
          "config:DescribeConfigurationRecorderStatus",
          "config:DescribeDeliveryChannels",
          "config:PutConfigurationRecorder",
          "config:PutDeliveryChannel",
          "config:StartConfigurationRecorder",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
      },
      {
        Effect   = "Allow"
        Action   = ["neptune-db:*"]
        Resource = "arn:aws:neptune-db:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_neptune_cluster.investigations.cluster_resource_id}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = "*"
      },
    ]
  })
}

data "archive_file" "config_sync" {
  type        = "zip"
  output_path = "${path.module}/../lambda/config_sync.zip"
  source {
    content  = file("${path.module}/../lambda/config_sync.py")
    filename = "config_sync.py"
  }
  source {
    content  = file("${path.module}/../lambda/neptune_client.py")
    filename = "neptune_client.py"
  }
}

resource "aws_lambda_function" "config_sync" {
  function_name    = "fis-chaos-config-sync"
  role             = aws_iam_role.config_sync.arn
  handler          = "config_sync.handler"
  runtime          = "python3.12"
  timeout          = 300
  filename         = data.archive_file.config_sync.output_path
  source_code_hash = data.archive_file.config_sync.output_base64sha256

  vpc_config {
    subnet_ids         = local.lambda_subnet_ids
    security_group_ids = [aws_security_group.neptune_feeder.id]
  }

  environment {
    variables = {
      NEPTUNE_ENDPOINT = aws_neptune_cluster.investigations.endpoint
      NEPTUNE_PORT     = "8182"
      REGIONS          = "${var.primary_agent_region},${var.secondary_agent_region}"
    }
  }
}

# --- Scheduled rule: sync every 5 minutes ---

resource "aws_cloudwatch_event_rule" "config_sync" {
  name                = "fis-chaos-config-sync"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "config_sync" {
  rule      = aws_cloudwatch_event_rule.config_sync.name
  target_id = "config-sync-lambda"
  arn       = aws_lambda_function.config_sync.arn
}

resource "aws_lambda_permission" "config_sync_eb" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.config_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.config_sync.arn
}

# --- Neptune Notebook (created via Neptune API — pre-configured with graph-notebook) ---

resource "aws_iam_role" "neptune_notebook" {
  name = "fis-chaos-neptune-notebook"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "neptune_notebook_sagemaker" {
  role       = aws_iam_role.neptune_notebook.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy_attachment" "neptune_notebook_neptune" {
  role       = aws_iam_role.neptune_notebook.name
  policy_arn = "arn:aws:iam::aws:policy/NeptuneFullAccess"
}

resource "aws_iam_role_policy" "neptune_notebook_s3" {
  name = "neptune-notebook-s3"
  role = aws_iam_role.neptune_notebook.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::aws-neptune-notebook", "arn:aws:s3:::aws-neptune-notebook/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["neptune-db:*"]
        Resource = "arn:aws:neptune-db:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_neptune_cluster.investigations.cluster_resource_id}/*"
      }
    ]
  })
}

# Neptune notebook via CLI (Terraform doesn't have a native neptune notebook resource)
resource "null_resource" "neptune_notebook" {
  depends_on = [aws_neptune_cluster.investigations, aws_iam_role_policy_attachment.neptune_notebook_neptune]

  provisioner "local-exec" {
    command = <<-EOF
      aws neptune create-db-cluster-endpoint --db-cluster-identifier fis-chaos-investigations --db-cluster-endpoint-identifier notebook --endpoint-type reader --region ${var.region} 2>/dev/null || true
      aws sagemaker delete-notebook-instance --notebook-instance-name fis-chaos-neptune-explorer --region ${var.region} 2>/dev/null || true
      sleep 10
      aws neptune create-db-cluster-snapshot --db-cluster-identifier fis-chaos-investigations --db-cluster-snapshot-identifier pre-notebook --region ${var.region} 2>/dev/null || true
    EOF
  }
}

output "neptune_notebook_instructions" {
  value       = "Create notebook: Console → Neptune → cluster 'fis-chaos-investigations' → Actions → Create notebook. Uses role: ${aws_iam_role.neptune_notebook.arn}"
  description = "Neptune notebook must be created via Console (Actions → Create notebook) for proper graph-notebook integration"
}

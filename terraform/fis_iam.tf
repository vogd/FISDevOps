# --- FIS IAM Role ---
resource "aws_iam_role" "fis" {
  name = "fis-chaos-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fis_logs" {
  name = "fis-cloudwatch-logs"
  role = aws_iam_role.fis.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogDelivery",
        "logs:PutResourcePolicy",
        "logs:DescribeResourcePolicies",
        "logs:DescribeLogGroups"
      ]
      Resource = "*"
    }]
  })
}

# --- CloudWatch Log Group for FIS ---
resource "aws_cloudwatch_log_group" "fis" {
  name              = "fis-chaos"
  retention_in_days = 7
}

# --- EKS Access Entry for FIS role ---
resource "aws_eks_access_entry" "fis" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.fis.arn
  type          = "STANDARD"
  kubernetes_groups = ["fis"]
}

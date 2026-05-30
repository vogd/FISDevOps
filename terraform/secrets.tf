# Secrets Manager — stores webhook endpoint config for global_forwarder.
# Secret VALUE is managed via CLI/install.sh (not terraform) to allow
# dynamic endpoint updates without redeployment.

resource "aws_secretsmanager_secret" "webhook_proxy" {
  name = "fis-chaos/webhook-proxy"

  replica {
    region = var.secondary_agent_region
  }

  lifecycle {
    ignore_changes = [replica]
  }
}

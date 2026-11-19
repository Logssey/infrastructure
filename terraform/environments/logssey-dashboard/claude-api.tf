# The credential value is provisioned directly into Secrets Manager. Terraform
# reads metadata only, so the API key never enters a plan or state file.
data "aws_secretsmanager_secret" "claude_api_key" {
  name = "${var.project}/${var.environment}/ai/claude-api-key"
}

data "aws_iam_policy_document" "claude_api_key" {
  statement {
    sid = "ReadClaudeApiCredential"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [data.aws_secretsmanager_secret.claude_api_key.arn]
  }
}

resource "aws_iam_role_policy" "claude_api_key" {
  name   = "${local.name_prefix}-claude-api-key"
  role   = aws_iam_role.source["api"].id
  policy = data.aws_iam_policy_document.claude_api_key.json
}

output "claude_api_key_secret_arn" {
  description = "Claude API credential reference for the dashboard API"
  value       = data.aws_secretsmanager_secret.claude_api_key.arn
}

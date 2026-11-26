# The value is provisioned outside Terraform so it never enters plan or state.
data "aws_secretsmanager_secret" "runtime_collector" {
  name = "${var.project}/${var.environment}/runtime/collector-token"
}

data "aws_iam_policy_document" "runtime_collector_host" {
  statement {
    sid = "ReadRuntimeCollectorToken"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [data.aws_secretsmanager_secret.runtime_collector.arn]
  }
}

resource "aws_iam_role_policy" "runtime_collector_host" {
  name   = "${local.name_prefix}-runtime-collector"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.runtime_collector_host.json
}

output "runtime_collector_secret_arn" {
  description = "Runtime collector token reference shared with the cluster"
  value       = data.aws_secretsmanager_secret.runtime_collector.arn
}

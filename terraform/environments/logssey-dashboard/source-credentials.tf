# The host obtains short-lived sessions for each application. Containers retain
# the IMDSv2 hop-limit boundary in main.tf and receive only their own role file.
data "aws_caller_identity" "source_credentials" {}
data "aws_partition" "source_credentials" {}

locals {
  source_secret_prefix = "${var.project}/${var.environment}/source-credentials/"
  source_secret_arn    = "arn:${data.aws_partition.source_credentials.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.source_credentials.account_id}:secret:${local.source_secret_prefix}*"
  source_components    = toset(["api", "worker"])
}

data "aws_iam_policy_document" "source_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.host.arn]
    }
  }
}

resource "aws_iam_role" "source" {
  for_each = local.source_components

  name                 = "${local.name_prefix}-role-secret-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.source_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "host_source_sessions" {
  statement {
    sid       = "AssumeApplicationSourceRoles"
    actions   = ["sts:AssumeRole"]
    resources = [for role in aws_iam_role.source : role.arn]
  }
}

resource "aws_iam_role_policy" "host_source_sessions" {
  name   = "${local.name_prefix}-source-sessions"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.host_source_sessions.json
}

data "aws_iam_policy_document" "source" {
  for_each = local.source_components

  statement {
    sid = "ReadConnectionCredentials"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [local.source_secret_arn]
  }

  dynamic "statement" {
    for_each = each.key == "api" ? [true] : []
    content {
      sid = "ManageConnectionCredentials"
      actions = [
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:DeleteSecret",
        "secretsmanager:TagResource",
      ]
      resources = [local.source_secret_arn]
    }
  }

  # These inventory APIs require Resource "*". No credential values are returned.
  statement {
    sid = "ReadIamKeyInventory"
    actions = [
      "iam:GetAccountSummary",
      "iam:GetAccessKeyLastUsed",
      "iam:ListUsers",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadAccountAccessKeyMetadata"
    actions   = ["iam:ListAccessKeys"]
    resources = ["arn:${data.aws_partition.source_credentials.partition}:iam::${data.aws_caller_identity.source_credentials.account_id}:user/*"]
  }

  statement {
    sid       = "ReadRegionalSecretInventory"
    actions   = ["secretsmanager:ListSecrets", "ssm:DescribeParameters"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "ReadBucketInventory"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "source" {
  for_each = local.source_components

  name   = "${local.name_prefix}-source-${each.key}"
  role   = aws_iam_role.source[each.key].id
  policy = data.aws_iam_policy_document.source[each.key].json
}

output "source_role_arns" {
  description = "호스트의 단기 세션 발급 설정에 넣는 API·워커 역할"
  value       = { for component, role in aws_iam_role.source : component => role.arn }
}

output "source_credentials_config" {
  description = "비밀값을 포함하지 않는 source-credentials.json 설정"
  value = {
    region          = var.region
    api_role_arn    = aws_iam_role.source["api"].arn
    worker_role_arn = aws_iam_role.source["worker"].arn
  }
}

output "source_secret_prefix" {
  value = local.source_secret_prefix
}

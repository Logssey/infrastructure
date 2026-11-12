# ─────────────────────────────────────────────
# IaC 보안 자산 그래프 수집 Role (scanner-ro)
#
# iac 네임스페이스의 Cartography CronJob(서비스 계정 cartography)만 IRSA 로 assume 한다.
# 보안 설정·메타데이터만 읽으면 되므로 AWS 관리형 SecurityAudit 을 쓴다 (Cartography 공식 문서 권장).
# plan-ro 와 같은 데이터 읽기 거부를 명시해, 관리형 정책이 바뀌어도 시크릿 값·버킷 객체는 읽지 못하게 한다.
# ─────────────────────────────────────────────

locals {
  scanner_service_account = "system:serviceaccount:iac:cartography"
}

data "aws_iam_policy_document" "scanner_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.k8s.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:sub"
      values   = [local.scanner_service_account]
    }
  }
}

resource "aws_iam_role" "scanner" {
  name                 = "${var.name_prefix}-role-iac-scanner-ro"
  assume_role_policy   = data.aws_iam_policy_document.scanner_assume.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-role-iac-scanner-ro"
  }
}

resource "aws_iam_role_policy_attachment" "scanner_security_audit" {
  role       = aws_iam_role.scanner.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

data "aws_iam_policy_document" "scanner_deny_data" {
  # 시크릿 값 (IaC 보안 PRD SR-4)
  statement {
    sid       = "DenySecretValue"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
  }

  # 버킷 객체 내용. 그래프에는 버킷 설정만 필요하다.
  statement {
    sid       = "DenyObjectRead"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "scanner_deny_data" {
  name   = "${var.name_prefix}-iac-scanner-deny-data"
  role   = aws_iam_role.scanner.id
  policy = data.aws_iam_policy_document.scanner_deny_data.json
}

# ─────────────────────────────────────────────
# IaC 보안 워커의 AWS 역할 (IaC 보안 ADR-13).
#
# 호스트 역할이 이 역할의 1시간 세션을 받아 /opt/logssey/aws-iac/worker 에 둔다
# (Secret 과 같은 publish-aws-credentials.py 를 IaC 설정으로 따로 돌린다. deploy/logssey-dashboard/README.md).
# 워커는 읽기만 한다: CloudFront 배포 목록(origin 보강), IAM 시뮬레이터(1등급 경로 확인).
# 시뮬레이터는 워커가 넘긴 정책 문서만 평가하고 계정의 정책을 읽거나 바꾸지 않는다.
#
# 수집 역할(collector)은 호스트의 매일 Cartography 수집이 /opt/logssey/aws-iac/collector 세션으로 쓴다.
# 예전 클러스터 수집 역할(scanner-ro, 11/19 삭제)과 같은 권한이다: 관리형 SecurityAudit 에
# 시크릿 값·버킷 객체 읽기 거부를 명시한다.
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "iac_worker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.host.arn]
    }
  }
}

resource "aws_iam_role" "iac_worker" {
  name                 = "${local.name_prefix}-role-iac-worker"
  description          = "IaC security worker: CloudFront distribution list and IAM policy simulation (read only)"
  assume_role_policy   = data.aws_iam_policy_document.iac_worker_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "iac_worker" {
  # 이 두 동작은 리소스 단위 권한을 지원하지 않는다.
  statement {
    sid       = "CloudFrontOrigins"
    actions   = ["cloudfront:ListDistributions"]
    resources = ["*"]
  }
  statement {
    sid       = "SimulateTierOnePaths"
    actions   = ["iam:SimulateCustomPolicy"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "iac_worker" {
  name   = "${local.name_prefix}-iac-worker"
  role   = aws_iam_role.iac_worker.id
  policy = data.aws_iam_policy_document.iac_worker.json
}

resource "aws_iam_role" "iac_collector" {
  name                 = "${local.name_prefix}-role-iac-collector"
  description          = "IaC security asset graph collection by Cartography on the dashboard host (read only)"
  assume_role_policy   = data.aws_iam_policy_document.iac_worker_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "iac_collector_security_audit" {
  role       = aws_iam_role.iac_collector.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

data "aws_iam_policy_document" "iac_collector_deny_data" {
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

resource "aws_iam_role_policy" "iac_collector_deny_data" {
  name   = "${local.name_prefix}-iac-collector-deny-data"
  role   = aws_iam_role.iac_collector.id
  policy = data.aws_iam_policy_document.iac_collector_deny_data.json
}

# 호스트 역할은 IaC 역할의 세션만 받을 수 있다 (Secret 역할 세션 정책과 따로 둔다).
data "aws_iam_policy_document" "host_iac_sessions" {
  statement {
    sid       = "AssumeIacRoles"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.iac_worker.arn, aws_iam_role.iac_collector.arn]
  }
}

resource "aws_iam_role_policy" "host_iac_sessions" {
  name   = "${local.name_prefix}-iac-sessions"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.host_iac_sessions.json
}

output "iac_worker_role_arn" {
  description = "/opt/logssey/iac-credentials.json 의 worker_role_arn"
  value       = aws_iam_role.iac_worker.arn
}

output "iac_collector_role_arn" {
  description = "/opt/logssey/iac-credentials.json 의 collector_role_arn"
  value       = aws_iam_role.iac_collector.arn
}

# ─────────────────────────────────────────────
# 호스트 역할: SSM 접속, 대시보드 이미지 받기, API·워커 단기 역할 발급.
# 애플리케이션 수집·비밀 저장 권한은 source-credentials.tf 의 두 역할에 둔다.
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "host_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "${local.name_prefix}-role-host"
  assume_role_policy = data.aws_iam_policy_document.host_assume.json
}

resource "aws_iam_role_policy_attachment" "host_ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "host_ecr_pull" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPullDashboardImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = concat(
      [for repo in aws_ecr_repository.this : repo.arn],
      [data.aws_ecr_repository.compliance_worker.arn],
    )
  }
}

resource "aws_iam_role_policy" "host_ecr_pull" {
  name   = "${local.name_prefix}-ecr-pull"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.host_ecr_pull.json
}

resource "aws_iam_instance_profile" "host" {
  name = "${local.name_prefix}-profile-host"
  role = aws_iam_role.host.name
}

# - ─────────────────────────────────────────────
# 스냅샷 정책(DLM)이 쓰는 서비스 역할
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${local.name_prefix}-role-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

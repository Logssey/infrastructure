# ─────────────────────────────────────────────
# IaC 보안 PR plan 전용 Role (plan-ro)
#
# infrastructure 레포의 PR 워크플로가 terraform plan 을 돌릴 때만 쓴다.
# 로컬 래퍼(make plan)에서도 목록의 IAM 사용자가 이 Role 의 임시 키로 plan 한다. (IaC 보안 ADR-12)
# 읽기 전용이며, plan 에 필요 없는 데이터(시크릿 값, 버킷 객체 내용)는 명시적으로 거부한다.
# apply 는 이 Role 로 할 수 없다. (IaC 보안 PRD SR-1, ADR-05)
#
# backend 가 S3 잠금 파일(use_lockfile)을 쓰므로 이 Role 로는 잠금을 잡을 수 없다.
# PR 워크플로와 make plan 은 terraform plan -lock=false 로 실행한다.
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "iac_plan_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # PR 이벤트만 허용한다. main 브랜치 실행(apply 용)은 받지 않는다.
    # sub 형식은 github-actions.tf 와 같다 (2026-07-15 이후 생성 레포는 ID 접미사가 붙음).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}@*/${var.iac_plan_repo}@*:pull_request"]
    }
  }

  # 로컬 래퍼(make plan). 세션 이름이 자기 IAM 사용자 이름일 때만 허용해,
  # CloudTrail 에서 누가 plan 했는지 세션 이름으로 구분한다.
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [for u in var.iac_plan_local_users : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${u}"]
    }

    condition {
      test     = "StringLike"
      variable = "sts:RoleSessionName"
      values   = ["$${aws:username}"]
    }
  }
}

resource "aws_iam_role" "iac_plan" {
  name                 = "${var.name_prefix}-role-iac-plan-ro"
  assume_role_policy   = data.aws_iam_policy_document.iac_plan_assume.json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-role-iac-plan-ro"
  }
}

# plan 의 refresh 는 관리 중인 모든 리소스 종류를 읽어야 하므로 AWS 관리형 ReadOnlyAccess 를 쓴다.
resource "aws_iam_role_policy_attachment" "iac_plan_readonly" {
  role       = aws_iam_role.iac_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess 에 포함되지만 plan 에는 필요 없는 데이터 읽기를 막는다.
# Deny 는 Allow 보다 우선한다.
data "aws_iam_policy_document" "iac_plan_deny_data" {
  # 시크릿 값 (IaC 보안 PRD SR-4)
  statement {
    sid       = "DenySecretValue"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
  }

  # 버킷 객체 내용. plan 은 버킷 설정만 읽으므로 tfstate 객체를 뺀 모든 객체 읽기를 막는다.
  # Terraform 이 관리하는 공개 객체(aws_s3_object)는 refresh 에 HeadObject(= s3:GetObject 권한)가 필요해 예외로 둔다.
  statement {
    sid     = "DenyObjectReadExceptState"
    effect  = "Deny"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = concat(
      ["arn:aws:s3:::${var.tfstate_bucket}/*"],
      [for arn in var.iac_plan_public_bucket_arns : "${arn}/*"],
    )
  }
}

resource "aws_iam_role_policy" "iac_plan_deny_data" {
  name   = "${var.name_prefix}-iac-plan-deny-data"
  role   = aws_iam_role.iac_plan.id
  policy = data.aws_iam_policy_document.iac_plan_deny_data.json
}

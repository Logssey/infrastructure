# ─────────────────────────────────────────────
# 대시보드 자동 배포: develop 머지 → GitHub Actions(테스트 → 이미지 push) → SSM 으로 호스트의 deploy.sh
#
# dashboard-backend·dashboard-frontend 의 develop 브랜치 워크플로만 역할을 받는다.
# 역할은 자기 ECR 한 곳에 push 하고, 이 호스트에 아래 SSM 문서 하나만 보낼 수 있다.
# 문서는 서비스 이름과 digest 만 받아 /opt/logssey/deploy.sh 를 부르므로 임의 명령은 보낼 수 없다.
# deploy.sh(레포 deploy/logssey-dashboard/)는 DB 덤프, .env digest 교체, 상태 확인, 실패 시 되돌리기를 한다.
# ─────────────────────────────────────────────

locals {
  deploy_targets = {
    api      = { repo = "dashboard-backend", ecr = "dashboard-api" }
    frontend = { repo = "dashboard-frontend", ecr = "dashboard-frontend" }
  }
}

# Re:Used prod 의 iam 모듈이 만든 GitHub OIDC 제공자를 읽기만 한다 (prod 상태는 읽지 않는다).
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_ssm_document" "deploy" {
  name            = "${local.name_prefix}-deploy"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy one Logssey dashboard image by digest (deploy/logssey-dashboard/deploy.sh)"
    parameters = {
      service = {
        type          = "String"
        allowedValues = ["api", "frontend"]
      }
      digest = {
        type           = "String"
        allowedPattern = "^sha256:[0-9a-f]{64}$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deploy"
      inputs = {
        timeoutSeconds = "900"
        runCommand     = ["/opt/logssey/deploy.sh {{ service }} {{ digest }}"]
      }
    }]
  })
}

data "aws_iam_policy_document" "deploy_assume" {
  for_each = local.deploy_targets

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 배포 브랜치의 실행만 받는다 (PR·다른 브랜치·environment 실행은 sub 가 달라 거부된다).
    # 2026-07-15 이후 만든 레포는 sub 에 조직·레포 ID 가 붙어 두 형식을 모두 둔다 (modules/iam/github-actions.tf).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${each.value.repo}:ref:refs/heads/${var.deploy_branch}",
        "repo:${var.github_org}@*/${each.value.repo}@*:ref:refs/heads/${var.deploy_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = local.deploy_targets

  name                 = "${local.name_prefix}-role-deploy-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume[each.key].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  for_each = local.deploy_targets

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # 자기 이미지 저장소 한 곳. 태그는 바꿀 수 없다 (ecr.tf IMMUTABLE).
  statement {
    sid = "EcrPushOwnImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.this[each.value.ecr].arn]
  }

  # 이 호스트에, 배포 문서만
  statement {
    sid       = "SendDeployCommand"
    actions   = ["ssm:SendCommand"]
    resources = [aws_instance.host.arn, aws_ssm_document.deploy.arn]
  }

  # 결과 읽기. 이 동작은 리소스 단위 권한을 지원하지 않는다.
  statement {
    sid       = "ReadDeployResult"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = local.deploy_targets

  name   = "${local.name_prefix}-deploy-${each.key}"
  role   = aws_iam_role.deploy[each.key].id
  policy = data.aws_iam_policy_document.deploy[each.key].json
}

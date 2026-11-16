# ─────────────────────────────────────────────
# Reach CI 의 ECR 읽기 역할 (dashboard-backend deploy/reach/ci/reach.yml 의 secret REACH_ECR_READ_ROLE_ARN).
#
# 서비스 레포의 Reach 워크플로가 Re:Used 이미지를 받아 스캔한다. 받기만 하고 실행하지 않는다.
#   - image  작업: CI/CD 가 끝난 뒤(workflow_run) 그 커밋의 pr-{sha} 이미지
#   - manual 작업: 대시보드 [스캔 요청](Reach API-01)이 workflow_dispatch 로 준 digest 이미지
# 두 작업 모두 기본 브랜치(develop)의 워크플로 파일로 돌아 sub 가 ref:refs/heads/develop 이다.
# PR 작업은 이미지를 받지 않으므로 PR 실행(sub ...:pull_request)은 이 역할을 받지 않는다.
# 같은 레포·브랜치의 다른 워크플로(CI/CD)도 sub 가 같아 받을 수 있지만, 권한이 아래 저장소 읽기뿐이다.
# Re:Used 이미지 저장소는 prod 가 만든 것을 읽기만 한다 (prod 상태는 읽지 않는다).
# ─────────────────────────────────────────────

locals {
  # 서비스 레포 → 그 레포의 Reach 워크플로가 받을 이미지 저장소.
  # 채팅 서버(Node)는 Reach L2 를 지원하지 않아 넣지 않았다.
  reach_ci_image_repositories = {
    "service-backend" = ["reused-api"]
  }
  # 서비스 레포의 GitHub 기본 브랜치 (대시보드 api.properties logssey.reach.ci.default-branch 와 같게)
  reach_ci_branch = "develop"
}

data "aws_ecr_repository" "reach_ci" {
  for_each = toset(flatten(values(local.reach_ci_image_repositories)))

  name = "${var.project}/${each.key}"
}

data "aws_iam_policy_document" "reach_ci_ecr_read_assume" {
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

    # 기본 브랜치 실행만. 2026-07-15 이후 만든 레포는 sub 에 조직·레포 ID 가 붙어 두 형식을 모두 둔다 (deploy.tf 와 같다).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([
        for repo in keys(local.reach_ci_image_repositories) : [
          "repo:${var.github_org}/${repo}:ref:refs/heads/${local.reach_ci_branch}",
          "repo:${var.github_org}@*/${repo}@*:ref:refs/heads/${local.reach_ci_branch}",
        ]
      ])
    }
  }
}

resource "aws_iam_role" "reach_ci_ecr_read" {
  name                 = "${local.name_prefix}-role-reach-ci-ecr-read"
  description          = "Reach CI in the service repos pulls Re:Used images to scan them (read only)"
  assume_role_policy   = data.aws_iam_policy_document.reach_ci_ecr_read_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "reach_ci_ecr_read" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # digest·태그 찾기(DescribeImages)와 받기만. push·삭제는 없다.
  statement {
    sid = "EcrPullServiceImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for repo in data.aws_ecr_repository.reach_ci : repo.arn]
  }
}

resource "aws_iam_role_policy" "reach_ci_ecr_read" {
  name   = "${local.name_prefix}-reach-ci-ecr-read"
  role   = aws_iam_role.reach_ci_ecr_read.id
  policy = data.aws_iam_policy_document.reach_ci_ecr_read.json
}

output "reach_ci_ecr_read_role_arn" {
  description = "service-backend 레포 secret REACH_ECR_READ_ROLE_ARN 에 넣는다"
  value       = aws_iam_role.reach_ci_ecr_read.arn
}

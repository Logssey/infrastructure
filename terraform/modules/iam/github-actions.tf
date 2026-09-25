# ─────────────────────────────────────────────
# GitHub Actions OIDC
#
# GitHub Actions 가 AWS 에 접근할 때 액세스 키를 쓰지 않는다.
# 실행 시점에 GitHub 이 발급한 OIDC 토큰으로 Role 을 assume 하고
# 임시 자격증명을 받는다.
#
# 저장할 장기 자격증명이 없으므로 유출·로테이션 문제가 사라진다.
# ─────────────────────────────────────────────

# thumbprint_list 를 지정하지 않는다.
#
# AWS 는 2023-07 부터 GitHub OIDC 통신을 신뢰할 수 있는 루트 CA 라이브러리로
# 검증한다. 인증서 thumbprint 검증은 레거시가 되었고,
# provider v5.81.0 부터 이 인자가 Optional 로 바뀌었다.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # 토큰의 aud 클레임. AWS STS 를 대상으로 발급된 토큰만 받는다.
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "${var.name_prefix}-oidc-github"
  }
}

# ─────────────────────────────────────────────
# 신뢰 정책
#
# 조건을 빠뜨리면 누구의 GitHub Actions 든 이 Role 을 assume 할 수 있다.
# sub 클레임으로 조직·레포·브랜치를 특정해야 한다.
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # 토큰이 AWS STS 를 대상으로 발급되었는지 확인한다.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 2026-07-15 이후 생성된 레포의 sub 클레임에는
    # 조직 ID 와 레포 ID 가 접미사로 붙는다.
    #   repo:Logssey@329835088/service-backend@1372604005:pull_request
    #
    # ID 는 변하지 않으나 레포를 추가할 때마다 조회해야 하므로 와일드카드로 둔다.
    # `@*` 로 두면 Logssey 로 시작하는 다른 조직명(LogsseyFake 등)은 매칭되지 않는다.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = concat(
        [for repo in var.github_repos : "repo:${var.github_org}@*/${repo}@*:ref:refs/heads/main"],
        [for repo in var.github_repos : "repo:${var.github_org}@*/${repo}@*:pull_request"],
      )
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.name_prefix}-role-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  # 워크플로 실행 시간을 고려한 최대 세션 길이.
  # 기본값 1시간으로 충분하다.
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-role-github-actions"
  }
}

# ─────────────────────────────────────────────
# ECR 푸시 권한
#
# GetAuthorizationToken 은 리소스를 지정할 수 없어 * 를 쓴다.
# 실제 push·pull 은 지정한 리포지토리로만 제한된다.
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "github_actions_ecr" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name   = "${var.name_prefix}-github-actions-ecr"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}
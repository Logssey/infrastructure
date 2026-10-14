# ─────────────────────────────────────────────
# IAM OIDC 공급자 (쿠버네티스 서비스 계정)
#
# 파드가 projected 서비스 계정 토큰(audience sts.amazonaws.com)으로
# AssumeRoleWithWebIdentity 를 호출하면, STS 가 issuer_url 의 문서로 서명을 검증한다.
# 각 IRSA 역할은 신뢰 정책의 sub 조건으로 네임스페이스·서비스 계정을 특정한다.
#
#   system:serviceaccount:<namespace>:<service-account>
#
# thumbprint_list 는 지정하지 않는다 (github-actions.tf 와 같은 이유).
# ─────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "k8s" {
  url            = local.issuer_url
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "${var.name_prefix}-oidc-k8s"
  }
}

# ─────────────────────────────────────────────
# IRSA 시험용 Role
#
# irsa-test 네임스페이스의 irsa-test 서비스 계정만 assume 할 수 있다.
# 권한은 없다. sts:GetCallerIdentity 는 권한 없이 호출되므로
# 시험 파드에서 이 Role 로 나오는지만 확인한다.
# 시험이 끝나면 create_irsa_test_role = false 로 지운다.
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "irsa_test_assume" {
  count = var.create_irsa_test_role ? 1 : 0

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
      values   = ["system:serviceaccount:irsa-test:irsa-test"]
    }
  }
}

resource "aws_iam_role" "irsa_test" {
  count = var.create_irsa_test_role ? 1 : 0

  name                 = "${var.name_prefix}-role-irsa-test"
  assume_role_policy   = data.aws_iam_policy_document.irsa_test_assume[0].json
  max_session_duration = 3600

  tags = {
    Name = "${var.name_prefix}-role-irsa-test"
  }
}

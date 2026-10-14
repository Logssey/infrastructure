# ─────────────────────────────────────────────
# 쿠버네티스 서비스 계정 OIDC 발급자 공개 위치
#
# EKS 가 아닌 클러스터에서 IRSA(IAM Roles for Service Accounts)를 쓰려면
# AWS STS 가 발급자 주소의 OIDC 문서와 공개 키(JWKS)를 HTTPS 로 읽을 수 있어야 한다.
# 클러스터 기본 발급자(https://kubernetes.default.svc.cluster.local)는
# 클러스터 안에서만 보이므로, 문서 2개를 이 주소에 따로 공개한다.
#
#   https://k8s-oidc.<domain>/.well-known/openid-configuration
#   https://k8s-oidc.<domain>/openid/v1/jwks
#
# 버킷은 비공개로 두고 CloudFront(OAC)를 거쳐서만 읽힌다.
# 도메인을 고정하는 이유: 이 주소가 모든 서비스 계정 토큰의 iss 와
# IAM OIDC 공급자 URL 이 된다. 바뀌면 kube-apiserver 설정과 IRSA 신뢰 관계를 모두 다시 만들어야 한다.
#
# 운영: 서비스 계정 서명 키(sa.key)를 교체하면 jwks_json 을 다시 받아 apply 한다.
#       교체 중에는 이전 키와 새 키를 둘 다 넣어 둔다.
# ─────────────────────────────────────────────

locals {
  issuer_host = "k8s-oidc.${var.domain_name}"
  issuer_url  = "https://${local.issuer_host}"
}

resource "aws_s3_bucket" "oidc" {
  bucket = "${var.name_prefix}-s3-k8s-oidc"

  tags = {
    Name = "${var.name_prefix}-s3-k8s-oidc"
  }
}

resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── 문서 ──
#
# 키를 교체했을 때 STS 가 오래된 내용을 읽지 않도록 캐시는 5분으로 짧게 둔다.

resource "aws_s3_object" "openid_configuration" {
  bucket        = aws_s3_bucket.oidc.id
  key           = ".well-known/openid-configuration"
  content_type  = "application/json"
  cache_control = "max-age=300"

  content = jsonencode({
    issuer                                = local.issuer_url
    jwks_uri                              = "${local.issuer_url}/openid/v1/jwks"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
  })
}

resource "aws_s3_object" "jwks" {
  bucket        = aws_s3_bucket.oidc.id
  key           = "openid/v1/jwks"
  content_type  = "application/json"
  cache_control = "max-age=300"
  content       = var.jwks_json
}

# ── CloudFront ──

resource "aws_cloudfront_origin_access_control" "oidc" {
  name                              = "${var.name_prefix}-oac-k8s-oidc"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "oidc" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name_prefix} k8s service account OIDC discovery"
  price_class     = var.price_class

  aliases = [local.issuer_host]

  # 공개 키만 서빙하는 정적 문서라 WAF 는 붙이지 않는다 (Web ACL 비용 절감).

  origin {
    domain_name              = aws_s3_bucket.oidc.bucket_regional_domain_name
    origin_id                = "s3-k8s-oidc"
    origin_access_control_id = aws_cloudfront_origin_access_control.oidc.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-k8s-oidc"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "${var.name_prefix}-cf-k8s-oidc"
  }
}

# 이 배포에서 온 읽기만 허용한다.
data "aws_iam_policy_document" "oidc_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.oidc.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.oidc.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  policy = data.aws_iam_policy_document.oidc_bucket.json
}

# ── Route 53 ──

resource "aws_route53_record" "oidc" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.zone_id
  name    = local.issuer_host
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.oidc.domain_name
    zone_id                = aws_cloudfront_distribution.oidc.hosted_zone_id
    evaluate_target_health = false
  }
}

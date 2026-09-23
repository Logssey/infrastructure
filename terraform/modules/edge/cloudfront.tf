# ─────────────────────────────────────────────
# CloudFront Distribution
#
# TLS 는 여기서 한 번, Public NLB 에서 한 번 종단된다.
# 클라이언트 → CloudFront 는 us-east-1 인증서,
# CloudFront → NLB 는 ap-northeast-1 인증서를 사용한다.
#
# 생성과 수정 모두 전 세계 엣지 전파에 5~15분이 걸린다.
# terraform apply 가 완료를 기다린다.
# ─────────────────────────────────────────────

# AWS 관리형 캐시 정책
#
# 직접 정의할 수도 있으나 관리형 정책이 일반적인 요구를 충족한다.
# CachingOptimized 는 압축을 활성화하고 쿼리스트링·쿠키·헤더를
# 캐시 키에서 제외한다.

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# AWS 관리형 오리진 요청 정책
#
# AllViewer 는 뷰어의 모든 헤더·쿠키·쿼리스트링을 오리진에 전달한다.
# WebSocket 의 Upgrade, Connection 헤더도 포함된다.

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name_prefix} distribution"
  price_class     = var.price_class

  aliases = [
    var.domain_name,
    "www.${var.domain_name}",
  ]

  web_acl_id = var.waf_enabled ? aws_wafv2_web_acl.main[0].arn : null

  # ── 오리진 ──
  #
  # NLB 의 기본 DNS 이름으로는 퍼블릭 인증서를 발급할 수 없어
  # origin.<domain> 을 별도로 두었다.
  # Custom Origin 에 HTTPS 로 연결하려면 오리진 도메인에 대한
  # 퍼블릭 신뢰 인증서가 필요하다.

  origin {
    origin_id   = "nlb-origin"
    domain_name = var.origin_domain

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ── 기본 동작 — 프론트엔드 ──

  default_cache_behavior {
    target_origin_id       = "nlb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress        = true
  }

  # ── /api/* ──
  #
  # 동적 응답이므로 캐싱하지 않는다.
  # 인증 헤더와 쿠키를 그대로 전달해야 한다.

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "nlb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    compress                 = true
  }

  # ── /socket.io/* ──
  #
  # WebSocket 은 CloudFront 가 기본 지원한다.
  # Upgrade, Connection 헤더가 오리진에 전달되어야 하므로
  # AllViewer 오리진 요청 정책을 사용한다.

  ordered_cache_behavior {
    path_pattern           = "/socket.io/*"
    target_origin_id       = "nlb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    compress                 = false
  }

  # ── /assets/* ──
  #
  # 정적 파일. 파일명에 해시가 포함된다는 전제로 장기 캐싱한다.

  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    target_origin_id       = "nlb-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress        = true
  }

  # ── 인증서 ──

  viewer_certificate {
    acm_certificate_arn = var.certificate_arn
    ssl_support_method  = "sni-only"

    # TLS 1.2 미만 차단
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # ── 지역 제한 없음 ──

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # 로깅은 비활성화한다. S3 버킷과 저장 비용이 필요하다.
  # 접근 분석이 필요해지면 logging_config 를 추가한다.

  tags = {
    Name = "${var.name_prefix}-cloudfront"
  }
}
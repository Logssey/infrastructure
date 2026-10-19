# ─────────────────────────────────────────────
# Grafana 전용 CloudFront Distribution
#
# 메인 배포에 alias 만 추가하지 않는 이유.
#
# CloudFront 의 cache behavior 는 경로(path)로만 분기한다.
# Host 로는 나눌 수 없다. 같은 배포에 grafana 를 넣으면
# "/" 요청이 default behavior 를 타고 CachingOptimized 로 캐시된다.
#
# Grafana 는 로그인 세션에 따라 응답이 달라지는 동적 앱이다.
# 캐시되면 다른 사용자의 화면이 보일 수 있다.
#
# 배포 자체는 무료다. 요청 수와 전송량으로만 과금된다.
# ─────────────────────────────────────────────

resource "aws_cloudfront_distribution" "grafana" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name_prefix} grafana"
  price_class     = var.price_class

  aliases = ["grafana.${var.domain_name}"]

  # 메인 배포와 같은 Web ACL 을 공유한다.
  #
  # Web ACL 은 개당 월 5 USD 다. 같은 관리형 룰을 쓸 것이라
  # 따로 만들 이유가 없다.
  web_acl_id = var.waf_enabled ? aws_wafv2_web_acl.main[0].arn : null

  origin {
    domain_name = "origin.${var.domain_name}"
    origin_id   = "nlb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ── 기본 동작 ──
  #
  # 단일 behavior 다. 경로별로 나눌 이유가 없다.
  # Grafana 는 정적 자산도 /public/build/ 아래에서 서빙하는데,
  # 파일명에 해시가 붙어 브라우저 캐시로 충분하다.
  default_cache_behavior {
    target_origin_id       = "nlb-origin"
    viewer_protocol_policy = "redirect-to-https"

    # Grafana 는 대시보드 저장, 패널 편집 등에 POST·PUT·DELETE 를 쓴다.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # 캐시하지 않는다.
    #
    # 로그인 상태에 따라 응답이 달라지고, 대시보드 데이터는
    # 실시간이어야 한다. 캐시하면 남의 세션 화면이 보일 수 있다.
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_disabled.id

    # 쿠키와 인증 헤더를 전달해야 세션이 유지된다.
    # Grafana 는 grafana_session 쿠키로 로그인 상태를 관리한다.
    #
    # Host 도 함께 전달되므로 HTTPRoute 매칭과
    # OAuth redirect_uri 생성이 올바르게 동작한다.
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    compress = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # 와일드카드 인증서(*.re-used.store)를 그대로 쓴다.
    # grafana 서브도메인이 여기 포함된다.
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "${var.name_prefix}-cf-grafana"
  }
}

# ── Route 53 레코드 ──

resource "aws_route53_record" "grafana" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.zone_id
  name    = "grafana.${var.domain_name}"
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.grafana.domain_name
    zone_id                = aws_cloudfront_distribution.grafana.hosted_zone_id
    evaluate_target_health = false
  }
}

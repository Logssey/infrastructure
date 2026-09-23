# ─────────────────────────────────────────────
# Route53 서비스 레코드
#
# alias 를 사용한다.
#   - apex 도메인에는 CNAME 을 둘 수 없다 (DNS 표준)
#   - 조회 비용이 없고 단계가 한 번 줄어든다
#
# ACM 검증용 CNAME 은 dns 모듈에 있다.
# ─────────────────────────────────────────────

# ── origin → Public NLB ──
#
# CloudFront 가 Custom Origin 으로 이 도메인에 HTTPS 로 접속한다.
# NLB 의 기본 DNS 이름으로는 퍼블릭 인증서를 발급할 수 없어 별도 도메인을 둔다.

resource "aws_route53_record" "origin" {
  zone_id = var.zone_id
  name    = var.origin_domain
  type    = "A"

  alias {
    name    = var.public_nlb_dns_name
    zone_id = var.public_nlb_zone_id

    # false 로 둔다.
    # true 면 NLB 타겟이 전부 unhealthy 일 때 DNS 응답 자체가 사라져
    # 원인 파악이 어려워진다.
    evaluate_target_health = false
  }
}

# ── apex, www → CloudFront ──
#
# 두 도메인이 같은 배포를 가리킨다. 리다이렉트하지 않는다.
# 중복 콘텐츠는 프론트엔드의 canonical 태그로 처리한다.
#
# CloudFront 가 IPv6 를 지원하므로 A 와 AAAA 를 모두 만든다.
# alias 레코드는 추가 비용이 없다.
#
# hosted_zone_id 는 CloudFront 의 전역 고정값이며
# 속성으로 참조해 하드코딩을 피한다.

locals {
  cloudfront_domains = {
    apex = var.domain_name
    www  = "www.${var.domain_name}"
  }

  cloudfront_record_types = ["A", "AAAA"]

  # 도메인 × 레코드 타입 조합
  cloudfront_records = {
    for pair in setproduct(keys(local.cloudfront_domains), local.cloudfront_record_types) :
    "${pair[0]}_${pair[1]}" => {
      name = local.cloudfront_domains[pair[0]]
      type = pair[1]
    }
  }
}

resource "aws_route53_record" "cloudfront" {
  for_each = local.cloudfront_records

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
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
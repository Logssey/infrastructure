# ─────────────────────────────────────────────
# Route53 Public Hosted Zone
#
# 도메인은 외부 등록기관(가비아)에서 구매했으므로
# Hosted Zone 생성 후 NS 레코드 4개를 등록기관에 등록해야 한다.
#
# CloudFront, ACM, 레코드는 스프린트 3에서 추가한다.
# ─────────────────────────────────────────────

resource "aws_route53_zone" "main" {
  name    = var.domain_name
  comment = "${var.name_prefix} public hosted zone"

  tags = {
    Name = "${var.name_prefix}-zone-public"
  }
}

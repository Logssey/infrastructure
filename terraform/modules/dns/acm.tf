# ─────────────────────────────────────────────
# ACM 인증서
#
# TLS 가 두 번 종단되므로 인증서도 두 개가 필요하다.
#   클라이언트 → CloudFront : us-east-1 인증서
#   CloudFront → Public NLB : ap-northeast-1 인증서
#
# CloudFront 는 us-east-1 리전의 인증서만 사용할 수 있다.
# 다른 리전에서 발급한 것은 연결되지 않는다.
#
# DNS 검증을 사용한다. 검증 레코드를 남겨두면 만료 전 자동 갱신된다.
# Email 검증은 매번 수동 승인이 필요하다.
#
# 퍼블릭 인증서는 발급과 갱신 모두 무료다.
# ─────────────────────────────────────────────

# ── CloudFront 용 (us-east-1) ──
#
# 와일드카드는 apex 를 포함하지 않는다.
# *.<domain> 은 www.<domain> 을 커버하지만 <domain> 자체는 커버하지 않는다.
# apex 를 주 도메인으로, 와일드카드를 SAN 으로 둔다.
#
# 와일드카드를 넣어두면 향후 서브도메인 추가 시 재발급이 불필요하다.

resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  tags = {
    Name = "${var.name_prefix}-acm-cloudfront"
  }

  # 인증서 교체 시 새 것을 먼저 만들고 기존 참조를 옮긴 뒤 삭제한다.
  lifecycle {
    create_before_destroy = true
  }
}

# 검증용 CNAME 레코드
#
# apex 와 와일드카드는 같은 검증 레코드를 사용한다.
# for_each 의 키를 domain_name 으로 두면 Terraform 은 두 항목으로 관리하나
# 실제 Route53 레코드는 하나로 합쳐진다.
#
# allow_overwrite 가 없으면 두 번째 항목이
# "레코드가 이미 존재한다" 에러로 실패한다.
resource "aws_route53_record" "cloudfront_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# 검증 완료까지 대기한다.
# 이 리소스를 참조하면 인증서가 준비된 뒤에 CloudFront 가 생성된다.
resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.cloudfront_validation : r.fqdn]
}

# ── Public NLB 용 (ap-northeast-1) ──
#
# CloudFront 가 Custom Origin 에 HTTPS 로 연결하려면
# 오리진 도메인에 대한 퍼블릭 신뢰 인증서가 필요하다.
# NLB 의 기본 DNS 이름으로는 인증서를 발급할 수 없어 별도 도메인을 둔다.

resource "aws_acm_certificate" "origin" {
  domain_name       = "origin.${var.domain_name}"
  validation_method = "DNS"

  tags = {
    Name = "${var.name_prefix}-acm-origin"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "origin_validation" {
  for_each = {
    for dvo in aws_acm_certificate.origin.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "origin" {
  certificate_arn         = aws_acm_certificate.origin.arn
  validation_record_fqdns = [for r in aws_route53_record.origin_validation : r.fqdn]
}
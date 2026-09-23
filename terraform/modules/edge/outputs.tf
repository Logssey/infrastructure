output "zone_id" {
  description = "Route53 Hosted Zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "name_servers" {
  description = <<-EOT
    NS 레코드 4개. 도메인 등록기관의 네임서버 설정에 입력한다.
    끝의 점(.)은 제외하고 입력한다.
  EOT
  value       = aws_route53_zone.main.name_servers
}

output "cloudfront_certificate_arn" {
  description = "CloudFront 용 ACM 인증서 ARN (us-east-1)"
  value       = aws_acm_certificate_validation.cloudfront.certificate_arn
}

output "origin_certificate_arn" {
  description = "Public NLB TLS 리스너용 ACM 인증서 ARN (ap-northeast-1)"
  value       = aws_acm_certificate_validation.origin.certificate_arn
}
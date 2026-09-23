output "cloudfront_distribution_id" {
  description = <<-EOT
    CloudFront Distribution ID.

    캐시 무효화에 사용한다.
      aws cloudfront create-invalidation --distribution-id <id> --paths "/*"
  EOT
  value       = aws_cloudfront_distribution.main.id
}

output "cloudfront_domain_name" {
  description = "CloudFront 기본 도메인. 커스텀 도메인 없이 접속할 때 사용한다."
  value       = aws_cloudfront_distribution.main.domain_name
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN. waf_enabled 가 false 면 null 이다."
  value       = var.waf_enabled ? aws_wafv2_web_acl.main[0].arn : null
}
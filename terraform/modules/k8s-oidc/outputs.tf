output "issuer_url" {
  description = <<-EOT
    서비스 계정 발급자 주소.
    kube-apiserver 의 --service-account-issuer 첫 번째 값으로 쓴다.
  EOT
  value       = local.issuer_url
}

output "jwks_uri" {
  description = "kube-apiserver 의 --service-account-jwks-uri 값"
  value       = "${local.issuer_url}/openid/v1/jwks"
}

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

output "oidc_provider_arn" {
  description = "IRSA 역할의 신뢰 정책 Federated principal 로 쓴다."
  value       = aws_iam_openid_connect_provider.k8s.arn
}

output "irsa_test_role_arn" {
  description = "IRSA 시험 파드의 AWS_ROLE_ARN"
  value       = var.create_irsa_test_role ? aws_iam_role.irsa_test[0].arn : null
}

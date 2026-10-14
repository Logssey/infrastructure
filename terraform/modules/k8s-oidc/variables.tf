variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "domain_name" {
  description = "서비스 도메인. 발급자 주소는 k8s-oidc.<domain> 이 된다."
  type        = string
}

variable "zone_id" {
  description = "Route53 Hosted Zone ID"
  type        = string
}

variable "certificate_arn" {
  description = <<-EOT
    CloudFront 용 ACM 인증서 ARN (us-east-1).
    와일드카드(*.<domain>) 인증서를 그대로 쓴다.
  EOT
  type        = string
}

variable "jwks_json" {
  description = <<-EOT
    클러스터 서비스 계정 공개 키(JWKS).
    cp 노드에서 `kubectl get --raw /openid/v1/jwks` 결과를 그대로 넣는다.
    공개 키라 레포에 두어도 된다.
  EOT
  type        = string
}

variable "price_class" {
  description = "CloudFront 가격 등급"
  type        = string
  default     = "PriceClass_200"
}

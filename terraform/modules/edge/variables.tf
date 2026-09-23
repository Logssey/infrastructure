variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "domain_name" {
  description = "서비스 도메인"
  type        = string
}

# ── DNS 모듈에서 전달 ──

variable "zone_id" {
  description = "Route53 Hosted Zone ID"
  type        = string
}

variable "certificate_arn" {
  description = <<-EOT
    CloudFront 용 ACM 인증서 ARN.
    us-east-1 리전의 인증서여야 한다.
  EOT
  type        = string
}

# ── LB 모듈에서 전달 ──

variable "origin_domain" {
  description = <<-EOT
    CloudFront 가 연결할 오리진 도메인.
    origin.<domain> 이며 Public NLB 를 가리킨다.
  EOT
  type        = string
}

variable "public_nlb_dns_name" {
  description = "Public NLB DNS 이름. origin 레코드의 alias 대상"
  type        = string
}

variable "public_nlb_zone_id" {
  description = "Public NLB 의 Hosted Zone ID. 리전마다 다르다."
  type        = string
}

# ── WAF ──

variable "waf_enabled" {
  description = <<-EOT
    CloudFront 에 WAF Web ACL 을 연결한다.

    Web ACL 월 $5 + 관리형 룰 그룹당 $1 이 고정 과금된다.
    CloudFront 배포 전파에 5~15분이 걸린다.
  EOT
  type        = bool
  default     = true
}

# ── CloudFront ──

variable "price_class" {
  description = <<-EOT
    CloudFront 엣지 로케이션 범위.

    PriceClass_100 : 북미·유럽
    PriceClass_200 : + 아시아·중동·아프리카
    PriceClass_All : 전 세계

    한국 사용자 대상이므로 아시아 엣지가 필요하다.
  EOT
  type        = string
  default     = "PriceClass_200"
}
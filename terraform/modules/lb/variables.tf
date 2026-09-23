variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "vpc_id" {
  description = "타겟 그룹을 생성할 VPC ID"
  type        = string
}

# ── Subnet ──

variable "private_app_subnet_ids" {
  description = "Internal NLB 배치 서브넷"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public NLB 배치 서브넷"
  type        = list(string)
}

# ── Security Group ──

variable "internal_nlb_sg_id" {
  type = string
}

variable "public_nlb_sg_id" {
  type = string
}

# ── Target ──

variable "control_plane_instance_ids" {
  description = "Internal API NLB 타겟. Control Plane 인스턴스 ID"
  type        = list(string)
}

variable "worker_instance_ids" {
  description = "Public NLB 타겟. Worker 인스턴스 ID"
  type        = list(string)
}

variable "envoy_node_port" {
  description = <<-EOT
    Envoy Gateway NodePort. 루트 모듈에서 전달받는다.

    같은 값을 공유하는 곳:
      - security 모듈의 SG 2번 규칙
      - k8s/platform/envoy-gateway/envoyproxy.yaml 의 nodePort
  EOT
  type        = number
  default     = 30080
}

variable "origin_certificate_arn" {
  description = <<-EOT
    Public NLB TLS 리스너용 ACM 인증서 ARN.

    origin.<domain> 에 대한 인증서이며 edge 모듈에서 발급한다.
    CloudFront 가 Custom Origin 에 HTTPS 로 연결하려면
    오리진 도메인에 대한 퍼블릭 신뢰 인증서가 필요하다.
  EOT
  type        = string
}

variable "nlb_ssl_policy" {
  description = <<-EOT
    TLS 리스너 보안 정책.

    Terraform 기본값은 ELBSecurityPolicy-2016-08 이며 구버전 프로토콜을 포함한다.
    명시하지 않으면 스캐너에 검출되므로 반드시 지정한다.

    조회:
      aws elbv2 describe-ssl-policies --load-balancer-type network \
        --region ap-northeast-1 \
        --query "SslPolicies[?contains(SslProtocols,'TLSv1.3')].Name"
  EOT
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
}
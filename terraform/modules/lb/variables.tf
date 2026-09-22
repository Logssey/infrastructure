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

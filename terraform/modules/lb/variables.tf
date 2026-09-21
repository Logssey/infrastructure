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
  description = "Envoy Gateway NodePort. docs/02-security.md 의 SG 규칙과 일치해야 한다."
  type        = number
  default     = 30080
}

variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "azs" {
  description = "사용할 가용영역 목록"
  type        = list(string)
}

variable "instance_profile_name" {
  description = "EC2 인스턴스 프로파일 이름. iam 모듈에서 전달받는다."
  type        = string
}

# ── Subnet ──

variable "private_app_subnet_ids" {
  description = "Private-App Subnet ID 목록. CP / Worker / Redis 배치"
  type        = list(string)
}

variable "private_etcd_subnet_ids" {
  description = "Private-Etcd Subnet ID 목록"
  type        = list(string)
}

# ── Security Group ──

variable "control_plane_sg_id" {
  type = string
}

variable "etcd_sg_id" {
  type = string
}

variable "worker_sg_id" {
  type = string
}

variable "k8s_node_sg_id" {
  type = string
}

variable "redis_sg_id" {
  type = string
}

# ── 인스턴스 스펙 ──

variable "control_plane_instance_type" {
  description = "Control Plane 인스턴스 타입. kube-apiserver 등 합계 2.3 GiB 소요"
  type        = string
  default     = "t3.medium"
}

variable "etcd_instance_type" {
  type    = string
  default = "t3.small"
}

variable "worker_instance_type" {
  type    = string
  default = "t3.large"
}

variable "redis_instance_type" {
  type    = string
  default = "t3.small"
}

variable "control_plane_volume_size" {
  type    = number
  default = 30
}

variable "etcd_volume_size" {
  description = "etcd 볼륨. 용량보다 gp3 기본 IOPS 확보가 목적이다."
  type        = number
  default     = 30
}

variable "worker_volume_size" {
  type    = number
  default = 50
}

variable "redis_volume_size" {
  type    = number
  default = 20
}

# ── 사설 IP ──

variable "control_plane_private_ips" {
  description = "Control Plane 사설 IP. azs 순서와 대응"
  type        = list(string)
}

variable "etcd_private_ips" {
  type = list(string)
}

variable "worker_private_ips" {
  type = list(string)
}

variable "redis_private_ip" {
  type = string
}

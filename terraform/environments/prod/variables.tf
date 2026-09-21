# ─────────────────────────────────────────────
# 공통
# ─────────────────────────────────────────────

variable "project" {
  description = "프로젝트 식별자. 모든 리소스 이름의 접두사로 사용한다."
  type        = string
  default     = "logssey"
}

variable "environment" {
  description = "환경 구분. prod / dev"
  type        = string
  default     = "prod"
}

variable "owner" {
  description = "리소스 책임자. 태그로 부착되어 추적에 사용한다."
  type        = string
}

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-1"
}

variable "azs" {
  description = <<-EOT
    사용할 가용영역 3개.
    도쿄는 ap-northeast-1b가 신규 계정에 제공되지 않으므로 1a/1c/1d를 사용한다.
    t3.small/medium/large 가용 여부를 확인하여 선정했다 (2026-09-21).
  EOT
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]

  validation {
    condition     = length(var.azs) == 3
    error_message = "AZ는 정확히 3개여야 한다. etcd quorum과 topology spread가 3개 기준으로 설계되었다."
  }
}

# ─────────────────────────────────────────────
# 네트워크 CIDR
# ─────────────────────────────────────────────

variable "vpc_cidr" {
  description = "VPC CIDR. Pod/Service CIDR와 겹치지 않아야 한다."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public Subnet CIDR. azs 순서와 대응한다."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = <<-EOT
    Private-App Subnet CIDR. Control Plane, Worker, Redis를 배치한다.
    Overlay CNI를 전제로 /24로 산정했다. Pod가 VPC IP를 소비하지 않기 때문이다.
    AWS VPC CNI 또는 Cilium ENI 모드로 변경할 경우 /20 이상으로 재산정해야 한다.
  EOT
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24", "10.20.12.0/24"]
}

variable "private_etcd_subnet_cidrs" {
  description = "Private-Etcd Subnet CIDR. external etcd 전용 계층."
  type        = list(string)
  default     = ["10.20.20.0/24", "10.20.21.0/24", "10.20.22.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = "Private-Data Subnet CIDR. RDS Subnet Group 전용. 인터넷 경로 없음."
  type        = list(string)
  default     = ["10.20.30.0/24", "10.20.31.0/24", "10.20.32.0/24"]
}

# ─────────────────────────────────────────────
# 보안 모드
# ─────────────────────────────────────────────

variable "security_mode" {
  description = <<-EOT
    permissive : 1차 구축용. 스캔으로 발견할 취약 설정을 의도적으로 남긴다.
    strict     : 조치 완료 상태. 최소 권한 규칙만 적용한다.
    전환은 이 변수만 바꿔 apply한다.
  EOT
  type        = string
  default     = "permissive"

  validation {
    condition     = contains(["permissive", "strict"], var.security_mode)
    error_message = "security_mode는 permissive 또는 strict 여야 한다."
  }
}

variable "tfstate_bucket" {
  description = "Terraform 상태 파일 버킷. 노드 Role 의 접근을 차단하는 데 사용한다."
  type        = string
  default     = "logssey-prod-s3-tfstate"
}

# ─────────────────────────────────────────────
# 노드 사설 IP
#   역할별로 끝자리를 구분한다. docs/04-compute.md 참조
#   .10 = Control Plane / etcd, .20 = Worker, .30 = Redis
# ─────────────────────────────────────────────

variable "control_plane_private_ips" {
  description = "Control Plane 사설 IP. azs 순서와 대응"
  type        = list(string)
  default     = ["10.20.10.10", "10.20.11.10", "10.20.12.10"]
}

variable "etcd_private_ips" {
  description = "etcd 사설 IP"
  type        = list(string)
  default     = ["10.20.20.10", "10.20.21.10", "10.20.22.10"]
}

variable "worker_private_ips" {
  description = "Worker 사설 IP"
  type        = list(string)
  default     = ["10.20.10.20", "10.20.11.20", "10.20.12.20"]
}

variable "redis_private_ip" {
  description = "Redis 사설 IP. Private-App AZ-a 에 배치"
  type        = string
  default     = "10.20.10.30"
}

variable "domain_name" {
  description = "서비스 도메인. 가비아에서 구매"
  type        = string
  default     = "re-used.store"
}

variable "project" {
  description = "프로젝트 식별자. 모든 리소스 이름의 접두사로 사용한다."
  type        = string
  default     = "logssey"
}

variable "environment" {
  description = "이름 접두사 둘째 부분. 리소스 이름은 logssey-dashboard-*"
  type        = string
  default     = "dashboard"
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

variable "service_vpc_name" {
  description = "감시 대상 서비스 VPC 의 Name 태그. 다른 서비스에 설치할 때 바꾼다."
  type        = string
  default     = "logssey-prod-vpc"
}

variable "subnet_name" {
  description = "EC2 를 둘 private 서브넷의 Name 태그 (NAT 로 밖에 나갈 수 있어야 함)"
  type        = string
  default     = "logssey-prod-subnet-app-a"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "root_volume_size" {
  description = "GiB. OS 와 Docker 이미지"
  type        = number
  default     = 30
}

variable "data_volume_size" {
  description = "GiB. PostgreSQL 데이터"
  type        = number
  default     = 20
}

variable "snapshot_retain_count" {
  description = "데이터 볼륨 스냅샷 보관 개수 (하루 1개)"
  type        = number
  default     = 7
}
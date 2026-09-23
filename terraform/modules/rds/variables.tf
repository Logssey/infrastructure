variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "private_data_subnet_ids" {
  description = <<-EOT
    DB Subnet Group 에 등록할 서브넷 ID 목록.

    RDS 는 최소 2개 AZ 를 요구한다. Single-AZ 로 운영하더라도
    3개를 모두 등록해 Multi-AZ 전환 시 Subnet Group 수정이 필요 없게 한다.
  EOT
  type        = list(string)
}

variable "rds_sg_id" {
  description = "RDS 에 부착할 Security Group ID"
  type        = string
}

# ─────────────────────────────────────────────
# 엔진
# ─────────────────────────────────────────────

variable "engine_version" {
  description = <<-EOT
    PostgreSQL 버전. 메이저.마이너만 지정하면 해당 마이너의
    최신 AWS 리비전(-R1, -R2 등)이 적용된다.

    사용 가능한 버전 조회:
      aws rds describe-db-engine-versions --engine postgres \
        --region ap-northeast-1 --query 'DBEngineVersions[].EngineVersion' \
        --output text | tr '\t' '\n' | sort -V | tail -10
  EOT
  type        = string
  default     = "18.6"
}

variable "parameter_group_family" {
  description = <<-EOT
    파라미터 그룹 family. engine_version 의 메이저 버전과 일치해야 한다.
    18.x → postgres18
  EOT
  type        = string
  default     = "postgres18"
}

variable "instance_class" {
  description = <<-EOT
    인스턴스 클래스.

    db.t4g.micro (1 GiB) 는 최대 연결 수가 약 112 로 커넥션 풀 여유가 없다.
    db.t4g.small (2 GiB) 는 약 225 다.

    변경 시 재시작이 발생한다(수 분 다운타임).
  EOT
  type        = string
  default     = "db.t4g.small"
}

# ─────────────────────────────────────────────
# 스토리지
# ─────────────────────────────────────────────

variable "allocated_storage" {
  description = "초기 스토리지 크기 (GB)"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = <<-EOT
    스토리지 오토스케일링 상한 (GB).
    allocated_storage 보다 크면 오토스케일링이 활성화된다.
  EOT
  type        = number
  default     = 100
}

# ─────────────────────────────────────────────
# 데이터베이스
# ─────────────────────────────────────────────

variable "db_name" {
  description = "생성할 데이터베이스 이름"
  type        = string
  default     = "reused"
}

variable "master_username" {
  description = <<-EOT
    마스터 사용자명.

    기본값 postgres 는 스캐너가 먼저 시도하는 이름이므로 사용하지 않는다.
    애플리케이션은 이 계정을 직접 쓰지 않으며, 별도 계정을 SQL 로 생성한다.
  EOT
  type        = string
  default     = "logssey_admin"
}

# ─────────────────────────────────────────────
# 백업·유지보수
# ─────────────────────────────────────────────

variable "backup_retention_period" {
  description = <<-EOT
    자동 백업 보존 기간 (일). 최대 35.
    보존 기간 내 임의 시점 복원(PITR)이 가능하다.
    DB 크기까지는 스냅샷 저장 비용이 없다.
  EOT
  type        = number
  default     = 7
}

variable "backup_window" {
  description = <<-EOT
    백업 수행 시간대 (UTC).
    19:00-20:00 UTC = KST 04:00-05:00
  EOT
  type        = string
  default     = "19:00-20:00"
}

variable "maintenance_window" {
  description = <<-EOT
    유지보수 시간대 (UTC).
    sun:20:00-sun:21:00 UTC = KST 일요일 05:00-06:00

    백업 직후로 배치해 유지보수 전에 최신 백업이 확보되도록 한다.
  EOT
  type        = string
  default     = "sun:20:00-sun:21:00"
}

# ─────────────────────────────────────────────
# 고가용성
# ─────────────────────────────────────────────

variable "multi_az" {
  description = <<-EOT
    Multi-AZ 배치 여부. 활성화 시 비용이 2배가 된다.
    true 로 변경하면 다운타임 없이 전환된다.
  EOT
  type        = bool
  default     = false
}

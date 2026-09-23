# ─────────────────────────────────────────────
# DB Subnet Group
#
# RDS 는 최소 2개 AZ 를 요구한다. Single-AZ 로 운영하더라도
# 3개를 모두 등록해 Multi-AZ 전환 시 수정이 필요 없게 한다.
# 사용하지 않는 서브넷에 비용은 발생하지 않는다.
# ─────────────────────────────────────────────

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-rds-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = {
    Name = "${var.name_prefix}-rds-subnet-group"
  }
}

# ─────────────────────────────────────────────
# 파라미터 그룹
#
# 기본 그룹(default.postgres18)은 수정할 수 없다.
# 나중에 커스텀으로 교체하려면 인스턴스 수정과 재부팅이 필요하므로
# 처음부터 커스텀 그룹을 붙인다.
#
# family 는 engine_version 의 메이저 버전과 일치해야 한다.
# ─────────────────────────────────────────────

resource "aws_db_parameter_group" "this" {
  name   = "${var.name_prefix}-pg${split(".", var.engine_version)[0]}"
  family = var.parameter_group_family

  # 전송 구간 암호화(rds.force_ssl)는 파라미터를 지정하지 않는다.
  #
  # PostgreSQL 18 + RDS 조합에서 이 값은 Source=system, 기본값 1 이다.
  # 명시하면 AWS 가 기본값과 같다고 판단해 사용자 설정으로 저장하지 않고,
  # Terraform 은 매 plan 마다 다시 설정하려 시도해 diff 가 반복된다.
  #
  # 확인:
  #   aws rds describe-db-parameters --db-parameter-group-name <name> \
  #     --query "Parameters[?ParameterName=='rds.force_ssl'].[ParameterValue,Source]"
  #
  # 그룹 자체는 유지한다. 기본 그룹(default.postgres18)은 수정할 수 없으므로
  # 향후 파라미터 추가를 위해 커스텀 그룹을 미리 붙여둔다.

  tags = {
    Name = "${var.name_prefix}-pg${split(".", var.engine_version)[0]}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─────────────────────────────────────────────
# DB 인스턴스
#
# 비밀번호는 manage_master_user_password 로 AWS 가 생성해
# Secrets Manager 에 저장한다. Terraform 은 값을 알지 못하므로
# 상태 파일에 평문이 남지 않는다.
#
# password 인자와는 상호 배타적이다.
# ─────────────────────────────────────────────

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-rds"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # 마이너 버전 보안 패치를 유지보수 시간대에 자동 적용한다.
  # 끄면 deprecated 버전에 대해 AWS 가 임의 시점에 강제 업그레이드한다.
  auto_minor_version_upgrade = true

  # ── 스토리지 ──

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"

  # 생성 시점에만 설정할 수 있다. 사후 적용하려면
  # 스냅샷 → 암호화 복사 → 인스턴스 교체가 필요하다.
  # 자동 스냅샷은 이 설정을 상속한다.
  storage_encrypted = true

  # ── 데이터베이스 ──

  db_name  = var.db_name
  username = var.master_username
  port     = 5432

  manage_master_user_password = true

  # ── 네트워크 ──

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]

  # Private-Data 서브넷에 배치되며 인터넷 경로가 없다.
  publicly_accessible = false

  # availability_zone 은 지정하지 않는다.
  # 지정하면 해당 AZ 장애 시 복구 선택지가 줄어든다.

  multi_az = var.multi_az

  parameter_group_name = aws_db_parameter_group.this.name

  # ── 백업 ──

  backup_retention_period = var.backup_retention_period
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window
  copy_tags_to_snapshot   = true

  # ── 삭제 보호 ──
  #
  # Terraform destroy 와 콘솔 삭제가 모두 차단된다.
  # 삭제하려면 이 값을 false 로 바꿔 apply 한 뒤 진행한다.
  deletion_protection = true

  # 삭제 시 최종 스냅샷을 남긴다.
  # timestamp() 는 매 plan 마다 값이 달라져 불필요한 diff 를 만든다.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-rds-final"

  # ── 모니터링 ──
  #
  # 비용 관리를 위해 비활성화한다. 전부 재부팅 없이 변경 가능하다.
  performance_insights_enabled    = false
  monitoring_interval             = 0
  enabled_cloudwatch_logs_exports = []

  tags = {
    Name = "${var.name_prefix}-rds"
  }
}

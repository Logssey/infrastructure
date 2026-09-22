# ─────────────────────────────────────────────
# permissive 모드 전용 개방 규칙
#
# security_mode = "strict" 로 바꾸면 이 규칙들만 제거되고
# rules.tf 의 체인 규칙은 그대로 유지된다.
#
#   terraform apply -var="security_mode=strict"
#
# SG 규칙은 합집합으로 평가되므로 permissive 상태에서는 개방 규칙이
# 우선 적용된다. 체인 규칙이 실제로 동작하는지는 strict 전환 시점에
# 검증해야 한다.
#
# 대상은 모두 사설 서브넷에 위치해 인터넷에서 실제로 도달하지 않는다.
# 라우팅 테이블에 인바운드 경로가 없기 때문이다.
# Prowler는 SG 규칙 자체를 검사하므로 finding 은 정상 생성된다.
#
# Public NLB 는 제외한다. 0.0.0.0/0 으로 열면 실제 도달이 가능해져
# CloudFront·WAF 우회 경로가 열리기 때문이다.
# ─────────────────────────────────────────────

locals {
  permissive = var.security_mode == "permissive" ? 1 : 0
}

# NodePort 전 범위 개방
# 예상 finding: Security group allows unrestricted access
resource "aws_vpc_security_group_ingress_rule" "open_worker_nodeport" {
  count = local.permissive

  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 30000
  to_port           = 32767
  description       = "T2-REMOVE: NodePort range open"

  tags = {
    Name = "${var.name_prefix}-open-worker-nodeport"
    Tier = "T2-remove"
  }
}

# SSH 개방
# 예상 finding: SSH open to internet
resource "aws_vpc_security_group_ingress_rule" "open_node_ssh" {
  count = local.permissive

  security_group_id = aws_security_group.k8s_node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "T2-REMOVE: SSH open"

  tags = {
    Name = "${var.name_prefix}-open-node-ssh"
    Tier = "T2-remove"
  }
}

# PostgreSQL 개방
# 예상 finding: Database port open to internet
resource "aws_vpc_security_group_ingress_rule" "open_rds" {
  count = local.permissive

  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  description       = "T2-REMOVE: PostgreSQL open"

  tags = {
    Name = "${var.name_prefix}-open-rds"
    Tier = "T2-remove"
  }
}

# Redis 개방
# 예상 finding: Cache port open to internet
resource "aws_vpc_security_group_ingress_rule" "open_redis" {
  count = local.permissive

  security_group_id = aws_security_group.redis.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
  description       = "T2-REMOVE: Redis open"

  tags = {
    Name = "${var.name_prefix}-open-redis"
    Tier = "T2-remove"
  }
}

# Kubernetes API 개방
# 예상 finding: Kubernetes API open to internet
resource "aws_vpc_security_group_ingress_rule" "open_k8s_api" {
  count = local.permissive

  security_group_id = aws_security_group.internal_nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  description       = "T2-REMOVE: Kubernetes API open"

  tags = {
    Name = "${var.name_prefix}-open-k8s-api"
    Tier = "T2-remove"
  }
}

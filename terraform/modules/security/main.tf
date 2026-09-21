# ─────────────────────────────────────────────
# Security Group 정의
#
# 규칙은 rules.tf 에서 aws_vpc_security_group_*_rule 로 별도 부착한다.
# 인라인 ingress/egress 블록을 쓰면 SG 간 상호 참조 시 순환 의존이 발생하고,
# Terraform이 규칙 전체를 관리해 외부 추가분을 매번 제거하려 한다.
# ─────────────────────────────────────────────

resource "aws_security_group" "public_nlb" {
  name        = "${var.name_prefix}-sg-public-nlb"
  description = "Public NLB. CloudFront Origin-Facing Prefix List only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-sg-public-nlb"
  }
}

resource "aws_security_group" "internal_nlb" {
  name        = "${var.name_prefix}-sg-internal-nlb"
  description = "Internal NLB for kube-apiserver"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-sg-internal-nlb"
  }
}

resource "aws_security_group" "control_plane" {
  name        = "${var.name_prefix}-sg-control-plane"
  description = "Kubernetes control plane nodes"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-sg-control-plane"
  }
}

resource "aws_security_group" "etcd" {
  name        = "${var.name_prefix}-sg-etcd"
  description = "External etcd cluster"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-sg-etcd"
  }
}

resource "aws_security_group" "worker" {
  name        = "${var.name_prefix}-sg-worker"
  description = "Kubernetes worker nodes"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-sg-worker"
  }
}

# Control Plane / etcd / Worker 에 공통 부착한다.
# Cilium VXLAN, health check, Hubble, Ansible SSH 등 클러스터 내부 통신을
# 한곳에서 관리하기 위한 보조 SG다.
resource "aws_security_group" "k8s_node" {
  name        = "${var.name_prefix}-sg-k8s-node"
  description = "Common rules for all Kubernetes nodes"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-sg-k8s-node"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-sg-rds"
  description = "RDS PostgreSQL"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-sg-rds"
  }
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-sg-redis"
  description = "Redis EC2"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-sg-redis"
  }
}

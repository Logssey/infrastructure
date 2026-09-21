# ═══════════════════════════════════════════════
# 체인 규칙 — permissive / strict 공통
#
# 출발지를 SG ID로 지정한다. IP 변경에 영향받지 않는다.
# 규칙 번호는 docs/02-security.md 의 체인 규칙 표와 대응한다.
# ═══════════════════════════════════════════════

# ── 1. CloudFront → Public NLB ──
# permissive 모드에서도 제한한다. 0.0.0.0/0 으로 열면 인터넷에서
# 실제 도달이 가능해져 CloudFront·WAF 우회 경로가 열리기 때문이다.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc_security_group_ingress_rule" "public_nlb_from_cloudfront" {
  security_group_id = aws_security_group.public_nlb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "CloudFront origin-facing only"
}

# ── 2. Public NLB → Worker (Envoy NodePort) ──
# Client IP Preservation 비활성화를 전제로 한다.
# 활성 상태에서는 출발지가 CloudFront IP가 되어 SG 참조가 동작하지 않는다.
resource "aws_vpc_security_group_ingress_rule" "worker_from_public_nlb" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.public_nlb.id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30080
  description                  = "Envoy Gateway NodePort"
}

# ── 3. Worker → Internal NLB (kubelet → apiserver) ──
resource "aws_vpc_security_group_ingress_rule" "internal_nlb_from_worker" {
  security_group_id            = aws_security_group.internal_nlb.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "kubelet to apiserver"
}

# Control Plane 자신도 Internal NLB를 경유해 apiserver를 호출한다.
resource "aws_vpc_security_group_ingress_rule" "internal_nlb_from_control_plane" {
  security_group_id            = aws_security_group.internal_nlb.id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "control plane to apiserver"
}

# ── 4. Internal NLB → Control Plane ──
resource "aws_vpc_security_group_ingress_rule" "control_plane_from_internal_nlb" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.internal_nlb.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "apiserver"
}

# ── 5. Control Plane → etcd (client) ──
resource "aws_vpc_security_group_ingress_rule" "etcd_from_control_plane" {
  security_group_id            = aws_security_group.etcd.id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "tcp"
  from_port                    = 2379
  to_port                      = 2379
  description                  = "etcd client"
}

# ── 6. etcd → etcd (peer, Raft) ──
resource "aws_vpc_security_group_ingress_rule" "etcd_peer" {
  security_group_id            = aws_security_group.etcd.id
  referenced_security_group_id = aws_security_group.etcd.id
  ip_protocol                  = "tcp"
  from_port                    = 2380
  to_port                      = 2380
  description                  = "etcd peer (Raft)"
}

# ── 7. Control Plane → Worker (kubelet API) ──
resource "aws_vpc_security_group_ingress_rule" "worker_from_control_plane" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet API"
}

# ── 8. Cilium VXLAN 터널 ──
resource "aws_vpc_security_group_ingress_rule" "k8s_node_vxlan" {
  security_group_id            = aws_security_group.k8s_node.id
  referenced_security_group_id = aws_security_group.k8s_node.id
  ip_protocol                  = "udp"
  from_port                    = 8472
  to_port                      = 8472
  description                  = "Cilium VXLAN tunnel"
}

# ── 9. Cilium agent health check ──
resource "aws_vpc_security_group_ingress_rule" "k8s_node_cilium_health" {
  security_group_id            = aws_security_group.k8s_node.id
  referenced_security_group_id = aws_security_group.k8s_node.id
  ip_protocol                  = "tcp"
  from_port                    = 4240
  to_port                      = 4240
  description                  = "Cilium agent health check"
}

# ── 10. Hubble peer ──
resource "aws_vpc_security_group_ingress_rule" "k8s_node_hubble_peer" {
  security_group_id            = aws_security_group.k8s_node.id
  referenced_security_group_id = aws_security_group.k8s_node.id
  ip_protocol                  = "tcp"
  from_port                    = 4244
  to_port                      = 4244
  description                  = "Hubble peer"
}

# ── 11. Hubble Relay ──
resource "aws_vpc_security_group_ingress_rule" "worker_hubble_relay" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 4245
  to_port                      = 4245
  description                  = "Hubble Relay"
}

# ── 12. Ansible SSH (Kubespray) ──
# Control Plane 1번 노드에서 나머지 8대로 SSH 접속한다.
# 구축 완료 후 제거를 검토한다. 횡방향 이동 경로가 된다.
resource "aws_vpc_security_group_ingress_rule" "k8s_node_ssh" {
  security_group_id            = aws_security_group.k8s_node.id
  referenced_security_group_id = aws_security_group.k8s_node.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "Ansible SSH for Kubespray"
}

# ── 13. Worker → RDS ──
resource "aws_vpc_security_group_ingress_rule" "rds_from_worker" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL"
}

# ── 14. Worker → Redis ──
resource "aws_vpc_security_group_ingress_rule" "redis_from_worker" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Redis"
}

# ═══════════════════════════════════════════════
# 아웃바운드 — 전체 허용
#
# Kubespray 설치, 이미지 pull, 카카오 OIDC·LLM API 호출에 필요하다.
# 아웃바운드 제한은 Cilium NetworkPolicy 계층에서 다룬다.
# SG로 제한하면 Pod 단위 구분이 불가능해 의미가 없다.
# ═══════════════════════════════════════════════

locals {
  all_sg_ids = {
    public_nlb    = aws_security_group.public_nlb.id
    internal_nlb  = aws_security_group.internal_nlb.id
    control_plane = aws_security_group.control_plane.id
    etcd          = aws_security_group.etcd.id
    worker        = aws_security_group.worker.id
    k8s_node      = aws_security_group.k8s_node.id
    rds           = aws_security_group.rds.id
    redis         = aws_security_group.redis.id
  }
}

resource "aws_vpc_security_group_egress_rule" "allow_all" {
  for_each = local.all_sg_ids

  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound"
}

# ── 6-b. etcd → etcd (client) ──
# etcdctl 을 etcd 노드에서 실행할 때 다른 멤버의 2379 로 접속한다.
# Kubespray 의 endpoint health --cluster 체크가 이 경로를 사용한다.
resource "aws_vpc_security_group_ingress_rule" "etcd_client_internal" {
  security_group_id            = aws_security_group.etcd.id
  referenced_security_group_id = aws_security_group.etcd.id
  ip_protocol                  = "tcp"
  from_port                    = 2379
  to_port                      = 2379
  description                  = "etcd client between members"
}

# ─────────────────────────────────────────────
# 체인 규칙 — permissive / strict 공통
#
# 출발지를 SG ID로 지정한다. IP 변경에 영향받지 않는다.
# 규칙 번호는 docs/02-security.md 의 체인 규칙 표와 대응한다.
#
# 규칙을 추가할 때는 번호 순서에 맞는 위치에 넣고
# 문서의 표에도 함께 반영한다.
# ─────────────────────────────────────────────

# ── 1. CloudFront → Public NLB ──
# permissive 모드에서도 제한한다. 0.0.0.0/0 으로 열면 인터넷에서
# 실제 도달이 가능해져 CloudFront·WAF 우회 경로가 열리기 때문이다.
#
# origin-facing 은 CloudFront 엣지가 오리진에 접속할 때 쓰는 IP 목록이다.
# com.amazonaws.global.cloudfront 는 CloudFront 전체 IP 로 범위가 더 넓다.
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
#
# 포트는 EnvoyProxy CRD 의 nodePort 와 일치해야 한다.
# k8s/platform/envoy-gateway/envoyproxy.yaml 참조.
resource "aws_vpc_security_group_ingress_rule" "worker_from_public_nlb" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.public_nlb.id
  ip_protocol                  = "tcp"
  from_port                    = var.envoy_node_port
  to_port                      = var.envoy_node_port
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

# ── 3-b. Control Plane → Internal NLB ──
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

# ── 4-b. Worker → Control Plane (apiserver 직접) ──
# Cilium kube-proxy replacement 사용 시 eBPF 가 Service IP 를
# 백엔드(CP 노드의 6443)로 직접 변환한다. Internal NLB 를 거치지 않으므로
# Worker 에서 Control Plane 으로의 직접 경로가 필요하다.
#
# kube-proxy replacement 를 끄면 불필요해진다.
resource "aws_vpc_security_group_ingress_rule" "control_plane_from_worker" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "apiserver from worker (kube-proxy replacement)"
}

# ── 4-c. Control Plane → Control Plane (apiserver 직접) ──
# CP 위의 Pod 도 4-b 와 같은 경로를 쓴다.
resource "aws_vpc_security_group_ingress_rule" "control_plane_internal_6443" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "apiserver between control planes"
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

# ── 6-b. etcd → etcd (client) ──
# etcdctl 을 etcd 노드에서 실행할 때 다른 멤버의 2379 로 접속한다.
# Kubespray 의 endpoint health --cluster 체크가 이 경로를 사용한다.
# peer 포트(2380)는 Raft 전용이라 이 경로를 대체하지 않는다.
resource "aws_vpc_security_group_ingress_rule" "etcd_client_internal" {
  security_group_id            = aws_security_group.etcd.id
  referenced_security_group_id = aws_security_group.etcd.id
  ip_protocol                  = "tcp"
  from_port                    = 2379
  to_port                      = 2379
  description                  = "etcd client between members"
}

# ─────────────────────────────────────────────
# kubelet API (10250)
#
# 출발지 × 목적지 조합을 모두 열어야 한다. 방향마다 규칙이 필요하다.
#
#   출발지 \ 목적지 | Control Plane | Worker
#   Control Plane   |      7-b      |   7
#   Worker          |      7-c      |  7-d
#
# etcd 노드는 Kubernetes 노드가 아니므로 kubelet 이 동작하지 않는다.
# ─────────────────────────────────────────────

# ── 7. Control Plane → Worker ──
resource "aws_vpc_security_group_ingress_rule" "worker_from_control_plane" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet API"
}

# ── 7-b. Control Plane → Control Plane ──
# apiserver 가 CP 노드의 kubelet 에 접근한다.
# kubectl exec / logs / top, cilium connectivity test 가 이 경로를 사용한다.
resource "aws_vpc_security_group_ingress_rule" "control_plane_kubelet" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet API between control planes"
}

# ── 7-c. Worker → Control Plane ──
# metrics-server 등 워커에서 동작하는 컴포넌트가 CP 노드의 kubelet 을 조회한다.
resource "aws_vpc_security_group_ingress_rule" "control_plane_kubelet_from_worker" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet API from worker"
}

# ── 7-d. Worker → Worker ──
# metrics-server 가 워커에 배치되면 다른 워커와 자기 자신의 kubelet 을 조회한다.
resource "aws_vpc_security_group_ingress_rule" "worker_kubelet_internal" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet API between workers"
}

# ─────────────────────────────────────────────
# 클러스터 내부 통신 — sg-k8s-node
#
# Control Plane / etcd / Worker 에 공통 부착되는 보조 SG 다.
# 노드 역할과 무관하게 필요한 규칙을 한곳에서 관리한다.
# ─────────────────────────────────────────────

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

# ── 9-b. Cilium health check (ICMP) ──
# cilium-health 의 노드 간 프로브가 ICMP 를 사용한다.
# 없으면 Cluster health 가 1/N reachable 로 표시되어
# 다른 문제를 진단할 때 혼선을 준다.
resource "aws_vpc_security_group_ingress_rule" "k8s_node_icmp" {
  security_group_id            = aws_security_group.k8s_node.id
  referenced_security_group_id = aws_security_group.k8s_node.id
  ip_protocol                  = "icmp"
  from_port                    = -1
  to_port                      = -1
  description                  = "Cilium health check (ICMP)"
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

# ─────────────────────────────────────────────
# 데이터 계층
# ─────────────────────────────────────────────

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

# ─────────────────────────────────────────────
# 아웃바운드 — 전체 허용
#
# Kubespray 설치, 이미지 pull, 카카오 OIDC·LLM API 호출에 필요하다.
#
# SG 아웃바운드는 노드 단위로만 통제할 수 있다. Overlay CNI 구성에서
# Pod 트래픽은 노드 ENI 로 SNAT 되므로 어느 Pod 가 나가는지 구분되지 않는다.
# egress 통제는 Pod 라벨을 인식하는 Cilium NetworkPolicy 계층에서 다룬다.
# ─────────────────────────────────────────────

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

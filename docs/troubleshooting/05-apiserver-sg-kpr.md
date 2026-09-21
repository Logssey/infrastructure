# 05. Service ClusterIP 접속 불가 — apiserver SG 누락

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-21 |
| 단계 | kube-proxy replacement 전환 후 |
| 영향 | CoreDNS·hubble-relay 기동 실패 (04번에서 이어짐) |
| 환경 | Kubespray v2.31.0, Cilium 1.19.3, kube-proxy replacement |

## 배경

[04번 문서](04-kube-proxy-ipvs-conflict.md) 에서 kube-proxy 를 제거하고
Cilium kube-proxy replacement 로 전환했다.

전환 자체는 성공했다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
```

```
KubeProxyReplacement:    True   [ens5   10.20.10.20 ... (Direct Routing)]
```

eBPF 로드밸런서에도 정상 등록되었다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list | head
```

```
10.96.0.1:443/TCP (1)   10.20.10.10:6443/TCP (5) (1)
10.96.0.1:443/TCP (2)   10.20.11.10:6443/TCP (5) (2)
10.96.0.1:443/TCP (3)   10.20.12.10:6443/TCP (5) (3)
```

kube-proxy 도 완전히 제거되었다.

```bash
kubectl -n kube-system get ds
```

```
NAME           DESIRED   CURRENT   READY
cilium         6         6         6
cilium-envoy   6         6         6
nodelocaldns   6         6         6
```

**그럼에도 Service 접속은 여전히 실패했다.**

## 증상

```bash
kubectl run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c "wget -qO- --timeout=5 --no-check-certificate https://10.96.0.1:443/healthz 2>&1"
```

```
wget: download timed out
```

CoreDNS 도 그대로였다.

```
coredns-58cc5d8ddf-zk8kc        0/1   Running            0    35m
hubble-relay-6cf6b6fdf9-z4qlq   0/1   CrashLoopBackOff   21   84m
```

## 진단 과정

### 1. Service IP 가 아닌 노드 IP 로 직접 테스트

Service 변환이 문제인지 그 이후가 문제인지 가르는 시험이었다.

```bash
kubectl run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c "wget -qO- --timeout=5 --no-check-certificate https://10.20.10.10:6443/healthz 2>&1"
```

```
wget: download timed out
```

**노드 IP 직접 접속도 실패.** Service 변환 문제가 아니라
Pod 에서 나가는 트래픽 자체가 막힌 것이다.

### 2. Cilium iptables 규칙 확인

앞서 `iptables-save | grep -v KUBE- | iptables-restore` 로 규칙을 정리했기 때문에
Cilium 규칙까지 지워졌는지 확인했다.

```bash
ansible -i inventory/logssey/inventory.ini worker-a -m shell -b \
  -a "iptables-save | grep -c CILIUM"
```

```
79
```

Cilium masquerade 규칙은 정상이었다.

```
MASQUERADE  0 -- 10.244.0.0/24  !10.244.0.0/24  /* cilium masquerade non-cluster */
SNAT        0 -- !10.244.0.0/24 !10.244.0.0/24  /* cilium host->cluster masquerade */ to:10.244.0.75
```

### 3. Pod 네트워크 기본 동작 확인

```bash
kubectl run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c "ip addr show eth0 | grep inet; ip route; ping -c 2 -W 2 10.20.10.10"
```

```
inet 10.244.0.238/32 scope global eth0
default via 10.244.0.75 dev eth0
10.244.0.75 dev eth0 scope link

--- 10.20.10.10 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

**Pod → 노드 ping 은 100% 성공.** Pod IP 할당, 라우팅, SNAT 모두 정상이다.

ICMP 는 되는데 TCP 6443 이 안 된다면 네트워크 경로가 아니라 **포트 차단**이다.

### 4. 포트 직접 테스트

```bash
ansible -i inventory/logssey/inventory.ini worker-a -m shell -b \
  -a "timeout 3 bash -c 'echo > /dev/tcp/10.20.10.10/6443'; echo exit=\$?"
```

```
exit=124
```

**timeout — 방화벽 차단 확정.**

## 원인

Security Group 에 **Worker → Control Plane 의 6443 직접 경로가 없었다.**

설계상 통신 경로는 이러했다.

```
sg-worker → sg-internal-nlb : 6443
sg-internal-nlb → sg-control-plane : 6443
```

kubelet 이 Internal NLB 를 경유해 apiserver 에 접근한다는 전제였다.

그러나 **kube-proxy replacement 를 켜면 Cilium eBPF 가 Service IP 를
백엔드로 직접 변환한다.** 백엔드는 `10.20.10.10:6443` 즉 Control Plane 노드 자체이며
NLB 를 거치지 않는다.

```
Pod → 10.96.0.1:443
   ↓ eBPF 변환
   → 10.20.10.10:6443  (CP 노드 직접, NLB 우회)
   ↓
   SG 차단
```

kube-proxy 병행 구성일 때는 kube-proxy 가 처리해 증상이 다르게 나타났고,
replacement 로 바꾸면서 이 경로가 드러났다.

## 해결

Terraform 에 SG 규칙 두 개를 추가했다.

`terraform/modules/security/rules.tf`

```hcl
# ── Worker → Control Plane (apiserver 직접) ──
# Cilium kube-proxy replacement 사용 시 eBPF 가 Service IP 를
# 백엔드(CP 노드의 6443)로 직접 변환한다. Internal NLB 를 거치지 않으므로
# Worker 에서 Control Plane 으로의 직접 경로가 필요하다.
resource "aws_vpc_security_group_ingress_rule" "control_plane_from_worker" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "apiserver from worker (kube-proxy replacement)"
}

# CP 노드끼리도 필요하다. CP 위의 Pod 도 같은 경로를 쓴다.
resource "aws_vpc_security_group_ingress_rule" "control_plane_internal_6443" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "apiserver between control planes"
}
```

```bash
cd terraform/environments/prod
terraform apply
```

적용 직후 확인.

```bash
ansible -i inventory/logssey/inventory.ini worker-a -m shell -b \
  -a "timeout 3 bash -c 'echo > /dev/tcp/10.20.10.10/6443'; echo exit=\$?"
```

```
exit=0
```

CoreDNS 와 hubble-relay 를 재시작했다.

```bash
kubectl -n kube-system delete pod -l k8s-app=kube-dns
kubectl -n kube-system delete pod -l k8s-app=hubble-relay
```

```
coredns-58cc5d8ddf-4spzb        1/1   Running   0   47s
coredns-58cc5d8ddf-pxqjk        1/1   Running   0   47s
hubble-relay-6cf6b6fdf9-rhkpz   1/1   Running   0   41s
```

## 함께 해결한 문제 — cilium-health ICMP

진단 도중 `Cluster health: 1/6 reachable` 이 관찰되었다.

```bash
ansible -i inventory/logssey/inventory.ini cp-a -m shell -b \
  -a "CID=\$(crictl ps --name cilium-agent -q | head -1); crictl exec \$CID cilium-health status --verbose"
```

```
cp-c:
  Host connectivity to 10.20.11.10:
    ICMP to stack:   Connection timed out
    HTTP to agent:   OK, RTT=4.374797ms
```

**HTTP 프로브는 성공하고 ICMP 만 실패**했다.
SG 에 노드 간 ICMP 규칙이 없었기 때문이다.

```hcl
# ── Cilium health check (ICMP) ──
resource "aws_vpc_security_group_ingress_rule" "k8s_node_icmp" {
  security_group_id            = aws_security_group.k8s_node.id
  referenced_security_group_id = aws_security_group.k8s_node.id
  ip_protocol                  = "icmp"
  from_port                    = -1
  to_port                      = -1
  description                  = "Cilium health check (ICMP)"
}
```

적용 후 `Cluster health: 6/6 reachable` 로 정상화되었다.

이 항목은 실제 트래픽에 영향을 주지 않으나, 헬스 지표가 잘못 표시되어
다른 문제를 진단할 때 혼선을 준다.

## 진단 중 오판

ICMP 규칙이 없는 상태에서 `ping -M do` 로 MTU 테스트를 시도했다.

```bash
ping -c 2 -M do -s 1400 10.20.11.10   # 100% loss
ping -c 2 -M do -s 8000 10.20.11.10   # 100% loss
ping -c 2 -M do -s 8972 10.20.11.10   # 100% loss
```

모든 크기에서 실패해 MTU 문제로 오인했으나, **ICMP 자체가 차단된 상태**였다.
SSH 와 Ansible 은 정상 동작하고 있었으므로 크기와 무관한 실패라는 점을
먼저 확인했어야 했다.

Pod 안에서의 ping 은 성공했는데, 이는 Cilium 이 Pod 트래픽을 eBPF 로 처리해
호스트 SG 평가 경로가 달랐기 때문이다.

## 재발 방지

- Terraform 에 규칙이 포함되어 재발하지 않는다.
- `docs/02-security.md` 의 체인 규칙 표에 추가한다.
- Notion [1. 네트워크] 문서의 Security Group Chain 도 수정해야 한다.

추가된 규칙.

| 출발지 | 목적지 | 포트 | 용도 |
| --- | --- | --- | --- |
| sg-worker | sg-control-plane | TCP 6443 | apiserver (kube-proxy replacement) |
| sg-control-plane | sg-control-plane | TCP 6443 | apiserver (CP 간) |
| sg-k8s-node | sg-k8s-node | ICMP | cilium-health 프로브 |

## 교훈

**CNI 구성 변경이 네트워크 경로를 바꾼다.**

kube-proxy replacement 는 Service 처리 방식만 바꾸는 것으로 보이지만,
실제로는 **트래픽이 NLB 를 경유하지 않게 되어 방화벽 요구사항이 달라진다.**

설계 시 "kubelet 은 NLB 를 통해 apiserver 에 접근한다"는 전제로 SG 를 구성했는데,
이 전제가 CNI 설정에 따라 달라진다는 점을 반영하지 못했다.

**진단 순서가 중요하다.**

| 확인 | 의미 |
| --- | --- |
| Pod IP 할당·라우팅 | Pod 네트워크 기본 동작 |
| Pod → 노드 ping | L3 경로 |
| 포트 직접 테스트 | 방화벽 |
| Service IP 접속 | Service 변환 |

위에서부터 좁혀가야 한다. Service IP 만 테스트하면 어느 계층이 문제인지 알 수 없다.

**ICMP 가 막힌 환경에서 ping 기반 진단은 오해를 만든다.**
SG 에 ICMP 규칙이 없으면 모든 ping 이 실패하므로, MTU·경로 문제로 오인하기 쉽다.

## 참고

| 항목 | 경로 |
| --- | --- |
| SG 규칙 | `terraform/modules/security/rules.tf` |
| 설계 문서 | `docs/02-security.md` |
| 선행 문제 | `docs/troubleshooting/04-kube-proxy-ipvs-conflict.md` |
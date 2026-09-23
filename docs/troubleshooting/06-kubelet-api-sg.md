# 06. kubelet API 접근 불가 — 10250 SG 방향 누락

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-22 |
| 단계 | `cilium connectivity test`, metrics-server 설치 |
| 영향 | `kubectl exec`·`logs`·`top` 실패, 노드 메트릭 수집 불가 |
| 환경 | Kubespray v2.31.0, Cilium 1.19.3 |

같은 포트(10250)에서 방향 누락이 **두 차례** 발생했다.
1차는 Control Plane 으로 향하는 경로, 2차는 Worker 간 경로다.

---

## 1차 — Control Plane 으로 향하는 경로

### 증상

`cilium connectivity test` 가 시작하자마자 종료했다.

```
⚠️  Unable to detect Cilium version, assuming v1.18.3 for connectivity tests:
    unable to parse Cilium version on pod "cilium-jpnhm":
    command failed (pod=kube-system/cilium-jpnhm, container=cilium-agent):
    error dialing backend: dial tcp 10.20.10.10:10250: i/o timeout

failed to fetch cilium runtime config:
    command failed (pod=kube-system/cilium-g8f47, container=cilium-agent):
    error dialing backend: dial tcp 10.20.11.10:10250: i/o timeout
```

`10.20.10.10`, `10.20.11.10` 은 모두 **Control Plane 노드**다.

### 진단 과정

#### 1. 대상 주소 확인

에러에 나온 IP 가 Control Plane 이라는 점이 단서였다.

| IP | 노드 |
| --- | --- |
| 10.20.10.10 | cp-a |
| 10.20.11.10 | cp-c |

포트 10250 은 kubelet API 다. `kubectl exec`, `kubectl logs`, `kubectl top`,
그리고 apiserver 가 Pod 에 접근하는 모든 경로가 이 포트를 사용한다.

#### 2. 기존 SG 규칙 확인

`docs/02-security.md` 의 체인 규칙에는 한 방향만 정의되어 있었다.

```
7 | sg-control-plane | sg-worker | TCP 10250 | kubelet API
```

**Control Plane → Worker 방향뿐이고, Control Plane 노드로 향하는 경로가 없었다.**

지금까지 문제가 드러나지 않은 이유는 조회 대상이 워커 Pod 뿐이었기 때문이다.
`kubectl logs` 로 확인한 CoreDNS, hubble-relay 는 모두 워커에 있었다.

#### 3. 포트 테스트

```bash
timeout 3 bash -c 'echo > /dev/tcp/10.20.11.10/10250'; echo exit=$?
```

```
exit=124
```

timeout. 차단 확정.

### 해결

`terraform/modules/security/rules.tf`

```hcl
# ── 7-b. Control Plane → Control Plane (kubelet API) ──
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

# ── 7-c. Worker → Control Plane (kubelet API) ──
# metrics-server 등 워커에서 동작하는 컴포넌트가 CP 노드의 kubelet 을 조회한다.
resource "aws_vpc_security_group_ingress_rule" "control_plane_kubelet_from_worker" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet API from worker"
}
```

적용 후 확인.

```bash
timeout 3 bash -c 'echo > /dev/tcp/10.20.11.10/10250'; echo exit=$?
# exit=0

kubectl -n kube-system logs cilium-jpnhm --tail=5
# 정상 출력
```

---

## 2차 — Worker 간 경로

### 증상

7-b, 7-c 를 추가한 뒤 metrics-server 를 설치했으나
**Worker 3대의 메트릭만** 수집되지 않았다.

```
NAME       CPU(cores)   MEMORY(bytes)
cp-a       108m         1181Mi
cp-c       119m         1660Mi
cp-d       96m          1611Mi
worker-d   78m          1159Mi
worker-a   <unknown>    <unknown>
worker-c   <unknown>    <unknown>
```

metrics-server 로그.

```
E0922 04:28:15.809497  1 scraper.go:147] "Failed to scrape node, timeout to access kubelet"
  err="Get \"https://10.20.10.20:10250/metrics/resource\": context deadline exceeded" node="worker-a"
E0922 04:28:15.812976  1 scraper.go:147] "Failed to scrape node, timeout to access kubelet"
  err="Get \"https://10.20.11.20:10250/metrics/resource\": context deadline exceeded" node="worker-c"
```

### 진단

metrics-server Pod 는 worker-c 와 worker-d 에 배치되어 있었다.
두 Pod 모두 Worker 노드 접근에 실패했고, **자기 자신이 있는 노드조차**
수집하지 못했다.

```bash
ansible -i inventory/logssey/inventory.ini worker-c -m shell -b \
  -a "timeout 3 bash -c 'echo > /dev/tcp/10.20.10.20/10250'; echo exit=\$?"
```

```
exit=124
```

`sg-worker` 에 10250 인바운드 규칙이 `sg-control-plane` 출발만 있었다.
**Worker 에서 Worker 로 향하는 경로가 없었다.**

### 해결

```hcl
# ── 7-d. Worker → Worker (kubelet API) ──
# metrics-server 가 워커에 배치되면 다른 워커와 자기 자신의 kubelet 을 조회한다.
resource "aws_vpc_security_group_ingress_rule" "worker_kubelet_internal" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet API between workers"
}
```

적용 후 6대 전부 수집되었다.

```
NAME       CPU(cores)   MEMORY(bytes)
cp-a       108m         1181Mi
cp-c       119m         1660Mi
cp-d       96m          1611Mi
worker-a   60m          1362Mi
worker-c   58m          1404Mi
worker-d   78m          1159Mi
```

---

## 재발 방지

- Terraform 에 규칙 3개(7-b, 7-c, 7-d)가 포함되어 재발하지 않는다.
- `docs/02-security.md` 의 체인 규칙 표에 반영했다.

## 교훈

**같은 포트라도 방향마다 규칙이 필요하다.**

1차에서 이 교훈을 기록하고도 2차에서 같은 함정에 빠졌다.
7-b, 7-c 를 추가할 때 "Control Plane 으로 향하는 경로"만 검토했고
Worker 간 경로는 고려하지 않았다.

포트 하나에 대해 **출발지 × 목적지 조합을 표로 그려보는 것**이
빠뜨리지 않는 방법이다.

| 출발지 \ 목적지 | Control Plane | Worker |
| --- | --- | --- |
| **Control Plane** | 7-b | 7 |
| **Worker** | 7-c | 7-d |

컴포넌트를 설치하기 전에 필요한 통신 경로를 먼저 검토한다.

| 컴포넌트 | 필요한 경로 |
| --- | --- |
| metrics-server | 모든 노드의 kubelet:10250 |
| Prometheus | 노드 exporter, kubelet metrics |

## 참고

| 항목 | 경로 |
| --- | --- |
| SG 규칙 | `terraform/modules/security/rules.tf` |
| 설계 문서 | `docs/02-security.md` |
| 애드온 전제 조건 | `k8s/README.md` |
| 포트 차단 판별 | `docs/troubleshooting/README.md` |
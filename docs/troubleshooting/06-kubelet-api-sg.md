# 06. kubelet API 접근 불가 — Control Plane 10250 SG 누락

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-22 |
| 단계 | `cilium connectivity test` 실행 시 |
| 영향 | `kubectl exec`·`logs`·`top` 이 Control Plane 노드에서 실패, connectivity test 시작 불가 |
| 환경 | Kubespray v2.31.0, Cilium 1.19.3 |

## 증상

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

## 진단 과정

### 1. 대상 주소 확인

에러에 나온 IP 가 Control Plane 이라는 점이 단서였다.

| IP | 노드 |
| --- | --- |
| 10.20.10.10 | cp-a |
| 10.20.11.10 | cp-c |

포트 10250 은 kubelet API 다. `kubectl exec`, `kubectl logs`, `kubectl top`,
그리고 apiserver 가 Pod 에 접근하는 모든 경로가 이 포트를 사용한다.

### 2. 기존 SG 규칙 확인

`docs/02-security.md` 의 체인 규칙에는 한 방향만 정의되어 있었다.

```
7 | sg-control-plane | sg-worker | TCP 10250 | kubelet API
```

**Control Plane → Worker 방향뿐이고, Control Plane 노드로 향하는 경로가 없었다.**

지금까지 문제가 드러나지 않은 이유는 조회 대상이 워커 Pod 뿐이었기 때문이다.
`kubectl logs` 로 확인한 CoreDNS, hubble-relay 는 모두 워커에 있었다.

### 3. 포트 테스트

```bash
timeout 3 bash -c 'echo > /dev/tcp/10.20.11.10/10250'; echo exit=$?
```

```
exit=124
```

timeout. 차단 확정.

## 원인

Security Group 에 **Control Plane 노드의 kubelet API(10250) 인바운드 규칙이 없었다.**

설계 시 "Control Plane 이 Worker 의 kubelet 을 호출한다"는 방향만 고려했으나,
실제로는 반대 방향과 Control Plane 간 통신도 필요하다.

| 경로 | 사용처 |
| --- | --- |
| CP → CP | apiserver 가 CP 노드의 Pod 에 exec / logs |
| Worker → CP | metrics-server 등이 CP 노드 kubelet 에서 메트릭 수집 |

## 해결

Terraform 에 SG 규칙 두 개를 추가했다.

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

```bash
cd terraform/environments/prod
terraform apply
```

적용 후 확인.

```bash
timeout 3 bash -c 'echo > /dev/tcp/10.20.11.10/10250'; echo exit=$?
# exit=0

kubectl -n kube-system logs cilium-jpnhm --tail=5
# 정상 출력
```

## 재발 방지

- Terraform 에 규칙이 포함되어 재발하지 않는다.
- `docs/02-security.md` 의 체인 규칙 표에 7-b, 7-c 를 추가했다.

## 교훈

**같은 포트라도 방향마다 규칙이 필요하다.**

7번 규칙(CP → Worker)이 이미 있어서 "kubelet API 는 열려 있다"고 착각하기 쉬웠다.
SG 는 방향성이 있으므로 각 경로를 개별로 확인해야 한다.

**Worker → CP 규칙(7-c)은 아직 사용되지 않았다.**
metrics-server 설치 시 필요해질 것을 예상해 미리 추가했다.
컴포넌트를 설치하기 전에 통신 경로를 검토하면 같은 문제를 반복하지 않는다.

| 컴포넌트 | 필요한 경로 |
| --- | --- |
| metrics-server | 모든 노드의 kubelet:10250 |
| Prometheus | 노드 exporter, kubelet metrics |
| Hubble Relay | Cilium agent:4244 |

## 참고

| 항목 | 경로 |
| --- | --- |
| SG 규칙 | `terraform/modules/security/rules.tf` |
| 설계 문서 | `docs/02-security.md` |
| 포트 차단 판별 | `docs/troubleshooting/README.md` |
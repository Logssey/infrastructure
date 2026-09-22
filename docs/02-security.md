# 02. 보안 그룹 구현

> 설계 근거는 Notion [1. 네트워크 - Security Group Chain] 참조

## security_mode 변수

1차 구축과 조치 완료 상태를 Terraform 변수 하나로 전환한다.

| 값 | 의미 |
| --- | --- |
| `permissive` | 1차 구축. strict 규칙 + 개방 규칙을 함께 부착한다 |
| `strict` | 조치 완료. 개방 규칙만 제거된다 |

```bash
terraform apply -var="security_mode=strict"
```

개방 규칙을 별도 리소스로 두고 `count`로 분기한다. SG 규칙은 합집합으로 평가되므로
`permissive` 상태에서는 개방 규칙이 우선 적용되고, 제거하면 체인 규칙만 남는다.

## 태그 정책

Security Group 8개에는 `Name` 태그를 부착한다.

체인 규칙에는 태그를 부착하지 않고 `description`으로 용도를 남긴다.
SG 규칙 단위 태그는 provider 5.x에서 도입된 기능이며 `description`과 정보가 중복되고 규칙 수가 많아질수록 관리 부담만 늘어난다.

개방 규칙에만 `Name`과 `Tier = T2-remove` 태그를 부착한다.
콘솔에서 이름이 표시되는 규칙이 곧 제거 대상이 되어 식별이 쉬워진다.

## Security Group 목록

| 이름 | 부착 대상 |
| --- | --- |
| logssey-prod-sg-public-nlb | Public NLB |
| logssey-prod-sg-internal-nlb | Internal API NLB |
| logssey-prod-sg-control-plane | Control Plane ×3 |
| logssey-prod-sg-etcd | external etcd ×3 |
| logssey-prod-sg-worker | Worker ×3 |
| logssey-prod-sg-k8s-node | CP · etcd · Worker 공통 부착 |
| logssey-prod-sg-rds | RDS |
| logssey-prod-sg-redis | Redis EC2 |

## 체인 규칙 (두 모드 공통)

출발지를 CIDR이 아닌 SG ID로 지정한다. IP 변경에 영향받지 않는다.

| # | 출발지 | 목적지 | 포트 | 용도 |
| --- | --- | --- | --- | --- |
| 1 | CloudFront Prefix List | sg-public-nlb | TCP 443 | WAF 우회 차단 |
| 2 | sg-public-nlb | sg-worker | TCP 30080 | Envoy Gateway NodePort |
| 3 | sg-worker | sg-internal-nlb | TCP 6443 | kubelet → apiserver |
| 3-b | sg-control-plane | sg-internal-nlb | TCP 6443 | control plane → apiserver |
| 4 | sg-internal-nlb | sg-control-plane | TCP 6443 | apiserver |
| 4-b | sg-worker | sg-control-plane | TCP 6443 | apiserver 직접 (kube-proxy replacement) |
| 4-c | sg-control-plane | sg-control-plane | TCP 6443 | apiserver 직접 (CP 간) |
| 5 | sg-control-plane | sg-etcd | TCP 2379 | etcd client |
| 6 | sg-etcd | sg-etcd | TCP 2380 | etcd peer (Raft) |
| 6-b | sg-etcd | sg-etcd | TCP 2379 | etcd client between members |
| 7 | sg-control-plane | sg-worker | TCP 10250 | kubelet API |
| 7-b | sg-control-plane | sg-control-plane | TCP 10250 | kubelet API (CP 간) |
| 7-c | sg-worker | sg-control-plane | TCP 10250 | kubelet API (Worker → CP) |
| 7-d | sg-worker | sg-worker | TCP 10250 | kubelet API (Worker 간) |
| 8 | sg-k8s-node | sg-k8s-node | UDP 8472 | Cilium VXLAN 터널 |
| 9 | sg-k8s-node | sg-k8s-node | TCP 4240 | Cilium agent health check |
| 9-b | sg-k8s-node | sg-k8s-node | ICMP | Cilium health 노드 프로브 |
| 10 | sg-k8s-node | sg-k8s-node | TCP 4244 | Hubble peer |
| 11 | sg-worker | sg-worker | TCP 4245 | Hubble Relay |
| 12 | sg-k8s-node | sg-k8s-node | TCP 22 | Ansible SSH (Kubespray) |
| 13 | sg-worker | sg-rds | TCP 5432 | PostgreSQL |
| 14 | sg-worker | sg-redis | TCP 6379 | Redis |

- Management EC2를 두지 않으므로 `Management SG` 관련 규칙은 제외한다.
  kubectl은 Worker에, Kubespray는 Control Plane 1번 노드에 SSM으로 접속해 실행한다.
- 12번 SSH 규칙은 구축 완료 후 제거를 검토한다. 노드 간 횡방향 이동 경로가 된다.

### kubelet API(10250) 경로

포트 하나에 대해 출발지와 목적지 조합을 모두 확인한다.
방향별로 규칙이 필요하며, 한 방향이 열려 있다고 다른 방향이 되는 것은 아니다.

| 출발지 \ 목적지 | Control Plane | Worker |
| --- | --- | --- |
| **Control Plane** | 7-b | 7 |
| **Worker** | 7-c | 7-d |

etcd 노드는 Kubernetes 노드가 아니므로 kubelet 이 동작하지 않는다.

### 구축 중 추가한 규칙

설계 시 정의한 통신 경로가 실제 도구의 동작과 달라 구축 중 추가한 항목이다.
상세는 [troubleshooting](troubleshooting/) 참조.

| # | 추가 사유 | 문서 |
| --- | --- | --- |
| 6-b | Kubespray의 `etcdctl endpoint health --cluster` 체크가 etcd 노드에서 다른 멤버의 클라이언트 포트로 접속한다. peer 포트(2380)는 Raft 전용이라 이 경로를 대체하지 않는다. | [02](troubleshooting/02-etcd-client-sg.md) |
| 4-b, 4-c | Cilium kube-proxy replacement 사용 시 eBPF가 Service IP를 백엔드(CP 노드의 6443)로 직접 변환한다. Internal NLB를 거치지 않으므로 직접 경로가 필요하다. | [05](troubleshooting/05-apiserver-sg-kpr.md) |
| 9-b | `cilium-health`의 노드 간 프로브가 ICMP를 사용한다. 없으면 `Cluster health`가 1/N reachable로 표시되어 다른 문제 진단 시 혼선을 준다. | [05](troubleshooting/05-apiserver-sg-kpr.md) |
| 7-b, 7-c | `kubectl exec`·`logs`·`top` 과 apiserver 의 Pod 접근이 kubelet API(10250)를 사용한다. 설계 시 CP → Worker 방향만 정의했다. | [06](troubleshooting/06-kubelet-api-sg.md) |
| 7-d | metrics-server 가 워커에 배치되면 다른 워커와 자기 자신의 kubelet 을 조회한다. 7-b·7-c 추가 시 Worker 간 경로를 함께 검토하지 못해 뒤늦게 발견했다. | [06](troubleshooting/06-kubelet-api-sg.md) |

**4-b와 4-c는 CNI 설정에 따라 필요 여부가 달라진다.**
kube-proxy replacement를 끄면 트래픽이 Internal NLB를 경유하므로 불필요하다.

## permissive 추가 규칙 (strict에서 제거)

| 대상 | 규칙 | 예상 finding |
| --- | --- | --- |
| sg-worker | 0.0.0.0/0 → TCP 30000-32767 | Security group allows unrestricted access |
| sg-k8s-node | 0.0.0.0/0 → TCP 22 | SSH open to internet |
| sg-rds | 0.0.0.0/0 → TCP 5432 | Database port open to internet |
| sg-redis | 0.0.0.0/0 → TCP 6379 | Cache port open to internet |
| sg-internal-nlb | 0.0.0.0/0 → TCP 6443 | Kubernetes API open to internet |

**전부 사설 서브넷에 위치하므로 인터넷에서 실제로 도달하지 않는다.**
라우팅 테이블에 인바운드 경로가 없기 때문이다.
Prowler는 SG 규칙 자체를 검사하므로 finding은 정상적으로 생성된다.

### 예외 — sg-public-nlb

Public NLB는 `permissive` 모드에서도 CloudFront Origin-Facing Managed Prefix List로 제한한다.

`0.0.0.0/0`으로 열면 인터넷에서 실제로 도달 가능해져 CloudFront와 WAF를 우회하는
경로가 열린다. 다른 항목과 달리 실질적 침해 위험이 있으므로 처음부터 제한한다.

## 아웃바운드

모든 SG의 아웃바운드는 `0.0.0.0/0` 전체 허용으로 둔다.

- Kubespray 설치, 컨테이너 이미지 pull, 카카오 OIDC·LLM API 호출에 필요하다.
- 아웃바운드 제한은 NetworkPolicy 계층에서 다룬다. SG로 제한하면 Pod 단위 구분이
  불가능해 의미가 없다.

## 알려진 한계

Overlay CNI 구성에서 Pod가 VPC 외부로 나갈 때 출발지 IP가 노드 ENI로 변환된다.
따라서 RDS·Redis SG는 Pod 단위 구분이 불가능하며 `sg-worker` 전체를 허용할 수밖에 없다.

**NetworkPolicy가 없으면 워커의 모든 Pod가 RDS와 Redis에 접근할 수 있다.**
SG는 계층 경계만 담당하고 실질적 통제는 Cilium NetworkPolicy가 수행한다.

## 확인

제거 대상 규칙 조회

```bash
aws ec2 describe-security-group-rules \
  --filters "Name=tag:Tier,Values=T2-remove" \
  --region ap-northeast-1 \
  --query 'SecurityGroupRules[].[Description,FromPort,ToPort,CidrIpv4]' \
  --output table
```

특정 SG의 인바운드 규칙 조회

```bash
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=<SG_ID>" \
  --region ap-northeast-1 \
  --query 'SecurityGroupRules[?!IsEgress].[FromPort,CidrIpv4,ReferencedGroupInfo.GroupId,Description]' \
  --output table
```

포트 차단 여부 판별

```bash
timeout 3 bash -c 'echo > /dev/tcp/<IP>/<PORT>'; echo exit=$?
```

| 결과 | 의미 |
| --- | --- |
| `exit=0` | 정상 연결 |
| `Connection refused` (exit=1) | 포트 도달, 프로세스 없음 |
| `exit=124` | timeout — SG 차단 |
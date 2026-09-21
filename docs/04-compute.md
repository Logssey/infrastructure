# 04. Compute 구현

> 설계 근거는 Notion [4. Compute/Cluster] 참조

## 노드 구성

총 10대. 9대는 Kubernetes 클러스터, 1대는 클러스터 외부 Redis다.

| 역할 | 수량 | 타입 | vCPU/Mem | EBS |
| --- | --- | --- | --- | --- |
| Control Plane | 3 | t3.medium | 2 / 4 GiB | gp3 30GB |
| external etcd | 3 | t3.small | 2 / 2 GiB | gp3 30GB |
| Worker | 3 | t3.large | 2 / 8 GiB | gp3 50GB |
| Redis | 1 | t3.small | 2 / 2 GiB | gp3 20GB |

EBS 합계 350GB.

- Control Plane은 t3.medium이 최소선이다. kube-apiserver·controller-manager·
  scheduler·kubelet·Cilium agent 합계가 약 2.3 GiB이므로 t3.small(2 GiB)로는
  여유가 없다.
- etcd 볼륨은 용량이 아니라 지연 특성이 기준이다. DB 실사용량은 수십 MB 수준이나
  fsync 지연이 leader election 안정성에 직접 영향을 준다. gp3는 용량과 무관하게
  3,000 IOPS / 125 MB/s가 기본 제공되므로 30GB로 충분하다.

## 사설 IP 할당

역할별로 끝자리를 구분해 IP만으로 식별 가능하게 한다.
서브넷의 `.0`~`.3`과 `.255`는 AWS 예약이므로 `.10`부터 사용한다.

| 노드 | 서브넷 | 사설 IP | 부착 SG |
| --- | --- | --- | --- |
| cp-a | app-a | 10.20.10.10 | control-plane, k8s-node |
| cp-c | app-c | 10.20.11.10 | control-plane, k8s-node |
| cp-d | app-d | 10.20.12.10 | control-plane, k8s-node |
| worker-a | app-a | 10.20.10.20 | worker, k8s-node |
| worker-c | app-c | 10.20.11.20 | worker, k8s-node |
| worker-d | app-d | 10.20.12.20 | worker, k8s-node |
| redis-a | app-a | 10.20.10.30 | redis |
| etcd-a | etcd-a | 10.20.20.10 | etcd, k8s-node |
| etcd-c | etcd-c | 10.20.21.10 | etcd, k8s-node |
| etcd-d | etcd-d | 10.20.22.10 | etcd, k8s-node |

**사설 IP를 고정하는 이유** — Kubespray 인벤토리와 etcd 엔드포인트가 IP로 참조된다.
인스턴스를 재생성해도 IP가 유지되어야 인벤토리를 수정하지 않아도 된다.
`aws_instance`의 `private_ip` 인자로 지정하며, 사설 IP는 개수와 무관하게 무료다.

**퍼블릭 IP는 할당하지 않는다.** `associate_public_ip_address = false`.
전부 사설 서브넷이라 사용할 수 없으며, 할당하면 개당 월 $3.65가 발생한다.

## AMI

Ubuntu 24.04 LTS. SSM Public Parameter로 조회한다.

`/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id`

| 항목 | 값 |
| --- | --- |
| AMI ID | ami-0879aeb9a3801dce6 |
| 리전 | ap-northeast-1 |
| 조회 일시 | 2026-09-21 |

### AMI 갱신으로 인한 재생성 방지

`aws_instance`의 `ami` 속성은 ForceNew다. Canonical이 새 AMI를 게시하면
SSM Parameter 값이 바뀌고, 다음 `plan`에서 인스턴스 10대 전부에 대해
destroy/recreate 계획이 잡힌다.

```hcl
lifecycle {
  ignore_changes = [ami]
}
```

생성 시점의 AMI로 고정하고 이후 갱신은 별도 절차로 관리한다.
OS 패치는 노드에서 `apt upgrade`로 수행하고, AMI 교체가 필요하면
노드를 하나씩 교체하는 방식으로 진행한다.

## 접속 방식

SSH 키 페어를 생성하지 않는다.

| 목적 | 방식 |
| --- | --- |
| 운영자 접속 | SSM Session Manager |
| Ansible (Kubespray) | cp-a에서 `ssh-keygen` 후 나머지 9대에 공개키 배포 |

`.pem` 파일을 로컬에 두지 않으므로 유출 위험이 없다.
SSM 접속에는 인바운드 포트가 필요 없으며, 인스턴스가 SSM 엔드포인트로
아웃바운드 연결을 맺는 방식이다.

## user_data

Kubespray 실행 전 노드에 필요한 사전 설정을 넣는다.

| 항목 | 이유 |
| --- | --- |
| swap 비활성화 | kubelet이 swap을 허용하지 않음 |
| 커널 모듈 `overlay`, `br_netfilter` | 컨테이너 런타임과 CNI에 필요 |
| sysctl `net.bridge.bridge-nf-call-iptables=1` | Pod 간 통신 |
| sysctl `net.ipv4.ip_forward=1` | 노드 간 라우팅 |

Kubespray가 대부분 처리하지만 미리 설정하면 실행 시간이 줄고
실패 지점이 하나 줄어든다.

Redis 노드는 Kubernetes 클러스터에 속하지 않으므로 별도 user_data를 사용한다.

## IMDS

1차 구축에서는 IMDSv1을 허용한다.

| 항목 | 1차 | T2 |
| --- | --- | --- |
| http_tokens | optional | required |
| http_put_response_hop_limit | 2 | 1 |

예상 finding: `EC2 instance allows IMDSv1`

Self-managed 클러스터에는 IRSA가 없어 Pod가 IMDS로 노드 Role 자격증명에
접근할 수 있다. hop limit을 1로 낮추면 컨테이너에서 IMDS에 도달하지 못한다.
두 설정 모두 인스턴스 재시작 없이 변경 가능하다.

## EBS 암호화

1차 구축부터 활성화한다. (`encrypted = true`, SSE-EBS 기본 KMS 키)

의도적 취약 설정의 범위에서 제외하는 이유는 **조치 비용이 비대칭적**이기 때문이다.
EBS 암호화는 기존 볼륨에 사후 적용할 수 없어, 조치하려면
스냅샷 → 암호화 복사 → 새 볼륨 → 인스턴스 교체가 필요하다.
클러스터를 재구축하는 것과 같은 비용이다.

무중단 조치가 가능한 IMDSv1, SG 개방, IAM 과다 권한으로
스캔 재료는 충분히 확보된다.

## 예상 비용

| 항목 | 월 (USD) |
| --- | --- |
| Control Plane t3.medium × 3 | 113.88 |
| etcd t3.small × 3 | 56.94 |
| Worker t3.large × 3 | 227.76 |
| Redis t3.small × 1 | 18.98 |
| EBS gp3 350GB | 33.60 |
| 퍼블릭 IP | 0.00 |
| **합계** | **451.16** |

도쿄 리전 기준. T3 버스터블 크레딧 초과 시 vCPU-시간당 $0.05가 추가된다.
CloudWatch `CPUCreditBalance` 알람으로 감시한다.

## 확인

```bash
# AMI ID 조회
aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --region ap-northeast-1 \
  --query 'Parameter.Value' --output text

# 인스턴스 목록
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=logssey" "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,PrivateIpAddress,State.Name]' \
  --output table

# SSM 등록 상태 (SSM Agent 정상 동작 확인)
aws ssm describe-instance-information \
  --region ap-northeast-1 \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName]' \
  --output table
```
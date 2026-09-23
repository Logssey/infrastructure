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

### 사설 IP 고정

**사설 IP 는 지정할 수 있고 무료다.** 공인 IP 와 성격이 다르다.

| 구분 | 중지 후 재시작 | 인스턴스 재생성 | 비용 |
| --- | --- | --- | --- |
| 사설 IP (자동) | 유지 | 바뀜 | 무료 |
| 사설 IP (명시 지정) | 유지 | 유지 | 무료 |
| 공인 IP (자동) | 바뀜 | 바뀜 | 개당 월 $3.65 |
| EIP | 유지 | 유지 | 개당 월 $3.65 |

사설 IP 는 ENI 에 부여되며 VPC 안에서만 유효하다.
서브넷 범위 안의 빈 주소를 지정하면 그대로 할당된다.
공인 IP 는 AWS 풀에서 동적으로 배정되므로 고정하려면 EIP 가 필요하다.

**고정하는 이유** — Kubespray 인벤토리와 etcd 엔드포인트가 IP 로 참조된다.
인스턴스를 재생성해도 IP 가 유지되어야 인벤토리를 수정하지 않아도 된다.

같은 서브넷에서 해당 IP 를 이미 사용 중이면 생성이 실패한다.
인스턴스를 교체할 때는 기존 인스턴스를 먼저 제거해야 한다.

**퍼블릭 IP는 할당하지 않는다.** `associate_public_ip_address = false`.
전부 사설 서브넷이라 사용할 수 없다.

## AMI

Ubuntu 24.04 LTS. SSM Public Parameter로 조회한다.

`/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id`

| 항목 | 값 |
| --- | --- |
| AMI ID | ami-0879aeb9a3801dce6 |
| 리전 | ap-northeast-1 |
| 조회 일시 | 2026-09-21 |

`aws_ssm_parameter` 의 `value` 는 provider 가 일괄 sensitive 로 표시한다.
SecureString 일 가능성 때문이다. 이 파라미터는 AWS 가 공개하는 AMI ID 이므로
`nonsensitive()` 로 해제해 로그와 output 에 노출되도록 한다.

### AMI 갱신으로 인한 재생성 방지

`aws_instance`의 `ami` 속성은 ForceNew다. Canonical이 새 AMI를 게시하면
SSM Parameter 값이 바뀌고, 다음 `plan`에서 인스턴스 10대 전부에 대해
destroy/recreate 계획이 잡힌다.

```hcl
lifecycle {
  ignore_changes = [ami]
}
```

**자동 갱신을 허용하지 않는 이유.**

Terraform 은 노드를 순차 교체하지 않는다. drain 이나 클러스터 재조인 로직이
없으므로 10대를 병렬로 파괴하고 새로 만든다.
EC2 재생성은 루트 볼륨을 삭제하므로 etcd 데이터, 클러스터 상태,
kubelet 인증서가 모두 사라진다.

### AMI 교체 절차

**EC2 는 생성된 인스턴스의 AMI 를 변경할 수 없다.**
AMI 는 인스턴스를 만들 때 쓰는 템플릿이며, 생성 후에는 루트 볼륨만 존재한다.
중지 후 이미지를 바꾸는 방식은 존재하지 않는다.

| 목적 | 방법 |
| --- | --- |
| 보안 패치, 커널 업데이트 | 노드에서 `apt upgrade` |
| OS 메이저 업그레이드 | 노드 교체 |

일상적인 패치는 `apt upgrade` 로 충분하다. AMI 교체가 필요한 경우는
Ubuntu 24.04 에서 다음 LTS 로 올릴 때 정도다.

노드 교체는 한 대씩 진행한다.

```bash
# 1. 워크로드 이동
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force

# 2. 클러스터에서 제거
kubectl delete node <node>

# 3. 인스턴스 교체 (해당 노드만)
terraform apply -replace='module.compute.aws_instance.worker[0]'

# 4. 클러스터 재조인
#    Kubespray scale.yml 또는 cluster.yml 실행
```

`ignore_changes` 가 걸려 있어도 `-replace` 는 동작한다.
새 인스턴스는 그 시점의 SSM Parameter 값, 즉 최신 AMI 로 생성된다.

etcd 노드 교체는 quorum 을 고려해야 한다. 3대 중 1대씩만 교체하며,
교체 중에는 나머지 2대가 quorum 을 유지한다.

## 접속 방식

SSH 키 페어를 생성하지 않는다.

| 목적 | 방식 |
| --- | --- |
| 운영자 접속 | SSM Session Manager |
| Ansible (Kubespray) | cp-a에서 `ssh-keygen` 후 나머지 노드에 공개키 배포 |

`.pem` 파일을 로컬에 두지 않으므로 유출 위험이 없다.

### SSM 동작 방식

SSM 은 IAM 기반으로 동작하며 인바운드 포트를 요구하지 않는다.

```
1. EC2 에 SSM Agent 실행 (Ubuntu AMI 에 기본 포함)
2. 노드 IAM Role 의 AmazonSSMManagedInstanceCore 로 인증
3. Agent 가 SSM 엔드포인트로 아웃바운드 연결을 유지
4. 운영자가 start-session 호출
5. SSM 이 연결된 Agent 에 명령을 전달
```

Agent 가 먼저 나가서 연결을 맺으므로 SG 인바운드가 필요 없다.
아웃바운드 경로(NAT Gateway 또는 Interface Endpoint)는 필요하다.

운영자 권한은 노드 Role 과 별개다. IAM User 의 `ssm:StartSession` 권한으로
통제하며, 어느 인스턴스에 접속할 수 있는지도 IAM 정책으로 제한할 수 있다.

## user_data

Kubespray 실행 전 노드에 필요한 사전 설정을 넣는다.
Kubespray가 대부분 처리하지만 미리 설정하면 실행 시간이 줄고
실패 지점이 하나 줄어든다.

### k8s-node.sh — CP / etcd / Worker 공통

| 항목 | 이유 |
| --- | --- |
| swap 비활성화 | kubelet 이 swap 이 켜져 있으면 기동을 거부한다 |
| 커널 모듈 `overlay` | containerd 의 overlayfs 스토리지 드라이버 |
| 커널 모듈 `br_netfilter` | 브리지 트래픽을 iptables 가 볼 수 있게 한다 |
| sysctl `bridge-nf-call-iptables` | Pod 간 통신 시 iptables 규칙 적용 |
| sysctl `ip_forward` | 노드 간 패킷 포워딩 |
| **시간 동기화** | 노드 간 시간이 어긋나면 etcd 인증서 검증이 실패한다 |
| 완료 표식 | `/var/log/logssey-init-done` |

`/etc/fstab` 은 부팅 필수 파일이므로 수정 전 `.bak` 백업을 남긴다.

### redis.sh — Redis 전용

패키지 설치만 수행하고 **서비스는 중지·비활성 상태로 둔다.**

```bash
systemctl stop redis-server
systemctl disable redis-server
```

기본 설정(`bind 127.0.0.1`, 인증 없음)으로 기동되는 것을 막기 위함이다.
`requirepass`, `maxmemory`, AOF 설정은 SSM 접속 후 수동으로 진행하고
그 시점에 서비스를 활성화한다.

**비밀번호를 user_data 에 넣지 않는다.**
user_data 는 IMDS 의 `/latest/user-data` 로 조회할 수 있어
노드에 접근한 모든 프로세스가 평문으로 읽을 수 있다.
IMDSv1 이 허용된 상태에서는 SSRF 취약점을 통해 외부에서도 접근 가능하다.

## IMDS

1차 구축에서는 IMDSv1을 허용한다.

| 항목 | 1차 | T2 |
| --- | --- | --- |
| http_endpoint | enabled | enabled |
| http_tokens | optional | required |
| http_put_response_hop_limit | 2 | 1 |

예상 finding: `EC2 instance allows IMDSv1`

**hop limit 이 1차에서 2인 이유.**
AWS 기본값은 1 이나, 컨테이너 네트워크를 한 홉 거치는 Pod 에서는
응답이 소멸해 IMDS 에 도달하지 못한다.
1차 구축에서는 Pod 가 노드 Role 을 사용할 수 있어야 하므로 2 로 둔다.

T2 에서 1 로 낮추면 컨테이너에서 IMDS 접근이 차단된다.
IRSA 가 없는 구성에서 Pod 침해 시 자격증명 탈취를 막는 조치다.

두 설정 모두 인스턴스 재시작 없이 변경 가능하다.
IMDS 개념과 위험은 `docs/03-iam.md` 참조.

## EBS 암호화

1차 구축부터 활성화한다. (`encrypted = true`, SSE-EBS 기본 KMS 키)

의도적 취약 설정의 범위에서 제외하는 이유는 **조치 비용이 비대칭적**이기 때문이다.
EBS 암호화는 기존 볼륨에 사후 적용할 수 없어, 조치하려면
스냅샷 → 암호화 복사 → 새 볼륨 → 인스턴스 교체가 필요하다.
클러스터를 재구축하는 것과 같은 비용이다.

무중단 조치가 가능한 IMDSv1, SG 개방, IAM 과다 권한으로
스캔 재료는 충분히 확보된다.

루트 볼륨에도 `Name` 태그를 부착한다.
콘솔 Volumes 목록에서 어느 노드의 볼륨인지 식별하기 위함이다.

## 예상 비용

| 항목 | 단가 | 월 (USD) |
| --- | --- | --- |
| Control Plane t3.medium × 3 | $0.052/hr | 113.88 |
| etcd t3.small × 3 | $0.026/hr | 56.94 |
| Worker t3.large × 3 | $0.104/hr | 227.76 |
| Redis t3.small × 1 | $0.026/hr | 18.98 |
| EBS gp3 350GB | $0.096/GB | 33.60 |
| 퍼블릭 IP | — | 0.00 |
| **합계** | | **451.16** |

도쿄 리전 온디맨드 기준, 730시간 환산. 2026-09 시점 요금이다.

T3 는 기본이 Unlimited 모드다. 베이스라인을 초과해 지속 사용하면
vCPU-시간당 $0.05 가 추가된다. CloudWatch `CPUCreditBalance` 알람으로 감시한다.

실제 청구액은 Cost Explorer 에서 확인한다.

## 확인

AMI ID 조회

```bash
aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --region ap-northeast-1 \
  --query 'Parameter.Value' --output text
```

인스턴스 목록

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=logssey" "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,PrivateIpAddress,State.Name]' \
  --output table
```

IMDS 설정 확인

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=logssey" "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
  --output table
```

EBS 암호화 확인

```bash
aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=logssey-prod-ebs-*" \
  --region ap-northeast-1 \
  --query 'Volumes[].[Tags[?Key==`Name`]|[0].Value,VolumeType,Size,Encrypted]' \
  --output table
```

SSM 등록 상태

```bash
aws ssm describe-instance-information \
  --region ap-northeast-1 \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName]' \
  --output table
```

## SSM 접속

```bash
CP_A=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=logssey-prod-cp-a" "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target $CP_A --region ap-northeast-1
```

user_data 실행 검증

```bash
ls -l /var/log/logssey-init-done      # 완료 표식
swapon --show                          # 출력 없어야 함
lsmod | grep -E 'overlay|br_netfilter'
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward
timedatectl                            # NTP synchronized: yes
cloud-init status --long               # status: done
```

실행 로그는 `/var/log/cloud-init-output.log` 에 남는다.
user_data 내용은 콘솔의 Actions → Instance settings → Edit user data 에서도 확인할 수 있다.

## 구축 중 발생한 이슈 (2026-09-21)

신규 AWS 계정에서 첫 EC2 생성 시 두 에러가 발생했다.

| 에러 | 원인 |
| --- | --- |
| PendingVerification | 계정 검증 대기. 리전별 첫 EC2 요청 시 발생 |
| VcpuLimitExceeded (한도 5) | 검증 대기 중 임시 한도 적용 |

검증 완료 후 vCPU 한도가 32로 자동 복구되어 재시도만으로 해결했다.
별도 Service Quotas 상향 요청은 불필요했다.

노드 10대 합계 20 vCPU. Quota code `L-1216C47A`.

```bash
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-1216C47A \
  --region ap-northeast-1 --query 'Quota.Value' --output text
```
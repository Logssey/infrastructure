# 01. 네트워크 구현

> 설계 근거는 Notion [1. 네트워크] 참조

## 확정값

리전: ap-northeast-1   
AZ:  ap-northeast-1a / 1c / 1d

1b 는 신규 계정에 제공되지 않는다.
t3.small / medium / large 가용 여부를 확인해 세 AZ 를 선정했다 (2026-09-21).

AZ 는 정확히 3개를 전제로 설계했다. etcd quorum 과 Pod topology spread 가
3개 기준이므로 `azs` 변수에 validation 을 두어 다른 개수를 막는다.

### VPC

| 리소스 | 이름 | CIDR |
| --- | --- | --- |
| VPC | logssey-prod-vpc | 10.20.0.0/16 |

**DNS 속성 두 개를 모두 활성화한다. 기본값은 비활성이다.**

| 속성 | 값 | 효과 |
| --- | --- | --- |
| `enable_dns_support` | true | VPC 내부 DNS 해석 |
| `enable_dns_hostnames` | true | EC2 내부 DNS 이름 부여, RDS 엔드포인트 해석 |

`enable_dns_hostnames` 가 꺼져 있으면 RDS 엔드포인트를 VPC 안에서 해석할 수 없고
Interface Endpoint 의 Private DNS 도 동작하지 않는다.

### Subnet (12개)

계층 4종 × AZ 3개.

| 계층 | AZ | 이름 | CIDR | 배치 |
| --- | --- | --- | --- | --- |
| Public | 1a | logssey-prod-subnet-public-a | 10.20.0.0/24 | Public NLB ENI, NAT Gateway |
| Public | 1c | logssey-prod-subnet-public-c | 10.20.1.0/24 | Public NLB ENI |
| Public | 1d | logssey-prod-subnet-public-d | 10.20.2.0/24 | Public NLB ENI |
| Private-App | 1a | logssey-prod-subnet-app-a | 10.20.10.0/24 | CP, Worker, Redis, Internal NLB ENI |
| Private-App | 1c | logssey-prod-subnet-app-c | 10.20.11.0/24 | CP, Worker, Internal NLB ENI |
| Private-App | 1d | logssey-prod-subnet-app-d | 10.20.12.0/24 | CP, Worker, Internal NLB ENI |
| Private-Etcd | 1a | logssey-prod-subnet-etcd-a | 10.20.20.0/24 | external etcd |
| Private-Etcd | 1c | logssey-prod-subnet-etcd-c | 10.20.21.0/24 | external etcd |
| Private-Etcd | 1d | logssey-prod-subnet-etcd-d | 10.20.22.0/24 | external etcd |
| Private-Data | 1a | logssey-prod-subnet-data-a | 10.20.30.0/24 | RDS Subnet Group |
| Private-Data | 1c | logssey-prod-subnet-data-c | 10.20.31.0/24 | RDS Subnet Group |
| Private-Data | 1d | logssey-prod-subnet-data-d | 10.20.32.0/24 | RDS Subnet Group |

계층별로 3번째 옥텟을 10 단위로 띄웠다. AZ 를 늘리면 `.3`, `.13`, `.23`, `.33` 으로
확장할 수 있다.

#### /24 산정 근거

**Overlay CNI 를 전제로 한다.** Cilium VXLAN 모드에서 Pod 는 VPC IP 를 소비하지 않고
`10.244.0.0/16` 대역을 사용한다. 따라서 서브넷 IP 는 노드와 ENI 만 소비하며
`/24`(사용 가능 251개)로 충분하다.

**AWS VPC CNI 또는 Cilium ENI 모드로 전환하면 Pod 마다 VPC IP 를 소비한다.**
노드당 Pod 를 30개로 잡아도 AZ 당 수백 개가 필요하므로 `/20` 이상으로 재산정해야 한다.
서브넷 CIDR 은 생성 후 변경할 수 없으므로 CNI 변경은 사실상 재구축이다.

#### Public Subnet 퍼블릭 IP 자동 할당

`map_public_ip_on_launch` 를 false 로 둔다.

Public 서브넷에는 NLB 와 NAT Gateway 만 배치하며 둘 다 명시적으로 EIP 를 할당받는다.
EC2 를 두지 않으므로 자동 할당이 필요 없고, 실수로 인스턴스를 만들었을 때
퍼블릭 IP 가 붙는 것을 방지한다.

### Route Table (4개)

| 이름 | 연결 Subnet | 경로 |
| --- | --- | --- |
| logssey-prod-rt-public | Public ×3 | 0.0.0.0/0 → IGW |
| logssey-prod-rt-app | Private-App ×3 | 0.0.0.0/0 → NAT-a, S3 Prefix List → S3 Endpoint |
| logssey-prod-rt-etcd | Private-Etcd ×3 | 0.0.0.0/0 → NAT-a, S3 Prefix List → S3 Endpoint |
| logssey-prod-rt-data | Private-Data ×3 | local only |

S3 Prefix List 경로는 Endpoint 를 라우팅 테이블에 연결하면 자동으로 추가된다.
Terraform 코드에 명시하지 않는다.

**Private-Data 에는 기본 경로를 두지 않는다.**
RDS 는 인터넷에서 도달할 수 없고, RDS 가 외부로 나가는 경로도 존재하지 않는다.

#### Private-Etcd 의 NAT 경로

Kubespray 설치 시 OS 패키지와 etcd 바이너리 다운로드에 필요하다.
**설치 완료 후에는 아웃바운드가 발생하지 않으므로 경로 제거를 검토한다.**

제거하면 SSM 접속이 끊기므로 Interface Endpoint 3종
(`ssm`, `ssmmessages`, `ec2messages`)이 필요하다.
Interface Endpoint 는 ENI 당 시간 과금이므로 비용과 보안을 저울질해 결정한다.

### NAT Gateway

| 리소스 | 이름 | 배치 |
| --- | --- | --- |
| Internet Gateway | logssey-prod-igw | — |
| NAT Gateway | logssey-prod-nat-a | Public-1a |
| EIP (NAT용) | logssey-prod-eip-nat-a | — |

**AZ-a 에 1개만 배치한다.**

AZ 별 배치 시 NAT 3대와 EIP 3개로 비용이 3배가 된다.
1차 구축에서는 트래픽이 없으므로 단일 배치로 시작한다.

| 항목 | 내용 |
| --- | --- |
| 장애 영향 | AZ-a 장애 시 Private-App·Private-Etcd 전 계층의 아웃바운드 중단 |
| 실제 증상 | 컨테이너 이미지 pull 불가로 신규 Pod 기동 실패. 기존 Pod 는 유지 |
| AZ 간 전송료 | 다른 AZ 에서 NAT 경유 시 GB 당 $0.01. 트래픽 규모상 무시할 수준 |
| 이중화 판단 | 실 트래픽 발생 후 재검토 |

### S3 Gateway Endpoint

| 리소스 | 이름 | 연결 Route Table |
| --- | --- | --- |
| S3 Gateway Endpoint | logssey-prod-vpce-s3 | rt-app, rt-etcd |

**Gateway 유형은 시간당 요금이 없다.** Interface 유형(PrivateLink)은 ENI 당
과금되므로 1차 구축에서는 사용하지 않는다.

ECR 이미지 레이어가 S3 에 저장되므로 이미지 pull 트래픽이 NAT 를 우회해
데이터 처리 요금을 줄인다.

**Private-Data 는 연결하지 않는다.** RDS 는 S3 에 접근할 필요가 없다.

Gateway Endpoint 는 Security Group 으로 통제하지 않는다.
접근 제어는 Endpoint Policy 와 Bucket Policy 가 담당한다.

### Kubernetes 예약 대역

| 용도 | CIDR | 비고 |
| --- | --- | --- |
| Pod | 10.244.0.0/16 | VPC 외부 대역. Cilium VXLAN 캡슐화 |
| Service | 10.96.0.0/16 | 클러스터 내부 전용 |

VPC 대역(`10.20.0.0/16`)과 겹치지 않는다.
Pod 트래픽은 VXLAN 으로 캡슐화되므로 VPC 라우터가 Pod CIDR 을 알 필요가 없다.

Kubespray 기본값은 `10.233.x` 이나 설계 문서의 값과 일치시켜 혼선을 방지한다.

### 미사용 대역

| 범위 | 상태 |
| --- | --- |
| 10.20.3.0 ~ 10.20.9.255 | Public 계층 확장 여유 |
| 10.20.13.0 ~ 10.20.19.255 | Private-App 계층 확장 여유 |
| 10.20.23.0 ~ 10.20.29.255 | Private-Etcd 계층 확장 여유 |
| 10.20.33.0 ~ 10.20.255.255 | 미할당 |

## 의도적 취약 설정

### NACL 미적용

VPC 기본 NACL(전체 허용)을 그대로 사용한다.

- NACL 은 Stateless 이므로 응답용 임시 포트(1024-65535)를 반대 방향에 함께
  허용해야 한다. 규칙이 두 배로 늘고 하나만 누락돼도 통신이 끊기는데
  원인 추적이 어렵다.
- 서브넷 단위 통제라 인스턴스별 구분이 불가능하다. 세밀한 통제는 SG 가 담당한다.
- Private-Data 는 인터넷 기본 경로가 없어 실질적 노출 위험이 없다.

스캔 단계에서 "기본 NACL 이 전체 허용" finding 이 예상된다.

**T2 조치.** Private-Data 계층에만 NACL 을 생성한다.

| 방향 | 규칙 |
| --- | --- |
| Inbound | 5432 from 10.20.10.0/24, 10.20.11.0/24, 10.20.12.0/24 |
| Outbound | 1024-65535 to 위 세 대역 |

Private-App 이 3개 AZ 에 분산되어 있으므로 대역을 개별로 나열한다.
`10.20.8.0/21` 로 묶으면 미할당 대역까지 포함되므로 사용하지 않는다.

### S3 Endpoint Policy 미적용

Endpoint Policy 를 부착하지 않아 기본값인 전체 허용 상태다.
이 Endpoint 를 통해 임의의 S3 버킷에 접근할 수 있다.

**T2 조치.** 프로젝트가 사용하는 버킷으로 범위를 제한한다.
노드 Role 의 `logssey-prod-deny-tfstate` 인라인 정책이 상태 파일 버킷 접근을
이미 차단하고 있으나, Endpoint 계층에서도 제한하는 것이 다층 방어에 부합한다.

## 확인

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=logssey-prod-vpc" \
  --region ap-northeast-1 \
  --query 'Vpcs[].[VpcId,CidrBlock,EnableDnsSupport,EnableDnsHostnames]' \
  --output table
```

```bash
aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=logssey-prod-subnet-*" \
  --region ap-northeast-1 \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]' \
  --output table
```

```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=logssey-prod-rt-*" \
  --region ap-northeast-1 \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,length(Associations),length(Routes)]' \
  --output table
```

라우팅 테이블별 경로 상세.

```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=logssey-prod-rt-app" \
  --region ap-northeast-1 \
  --query 'RouteTables[0].Routes[].[DestinationCidrBlock,DestinationPrefixListId,GatewayId,NatGatewayId]' \
  --output table
```

`rt-app` 과 `rt-etcd` 에 S3 Prefix List 경로가 자동 추가되었는지 확인한다.
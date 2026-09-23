# Logssey · Infrastructure

Re:Used 중고거래 플랫폼의 클라우드 인프라 코드.

## 사전 요구사항

| 도구 | 버전 |
| --- | --- |
| Terraform | >= 1.10 |
| AWS CLI | v2 |
| Session Manager 플러그인 | EC2 접속 시 |

AWS 자격증명이 설정되어 있어야 한다.

```bash
aws sts get-caller-identity
```

## 시작하기

```bash
cd terraform/environments/prod

cp example.tfvars terraform.tfvars   # owner 값 채우기

terraform init       # provider 다운로드, S3 백엔드 연결 (최초 1회)
terraform fmt        # 코드 정렬
terraform validate   # 문법 검사
terraform plan       # 변경 예정 사항 확인
terraform apply      # 실제 적용
```

모듈을 새로 추가하면 `terraform init`을 다시 실행한다.

### 자주 쓰는 명령

```bash
# 전체 디렉터리 정렬 (modules/ 포함)
terraform fmt -recursive ../../

# 특정 모듈만 적용
terraform plan -target=module.network

# 보안 모드 전환 (개방 규칙 제거)
terraform apply -var="security_mode=strict"

# 특정 인스턴스만 재생성
terraform apply -replace='module.compute.aws_instance.worker[0]'

# 관리 중인 리소스 목록
terraform state list

# 출력값 확인
terraform output
terraform output -raw internal_api_dns_name
```

### EC2 접속

인바운드 포트를 열지 않으므로 SSM Session Manager로만 접속한다.

인스턴스 ID는 `terraform output`으로 확인한다.

```bash
cd terraform/environments/prod

terraform output control_plane_instance_ids
terraform output worker_instance_ids
terraform output etcd_instance_ids
terraform output redis_instance_id
```

```bash
aws ssm start-session --target <INSTANCE_ID> --region ap-northeast-1
```

cp-a 에 바로 접속하려면

```bash
CP_A=$(terraform output -json control_plane_instance_ids \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)[0])')

aws ssm start-session --target $CP_A --region ap-northeast-1
```

### 클러스터 접속

kubectl은 Control Plane 노드에서 실행한다.

```bash
aws ssm start-session --target $CP_A --region ap-northeast-1
sudo su - ubuntu
kubectl get nodes
```

Kubespray 실행 환경은 `~/kubespray`에 있다.

```bash
cd ~/kubespray && source .venv/bin/activate
```

---

## 생성된 AWS 리소스

Terraform 이 관리하는 리소스 목록이다.
CI/CD 와 관측성 스택은 클러스터 내부에 배포되므로 AWS 리소스가 아니다.

### 네트워크

| 리소스 | 수량 | 역할 |
| --- | --- | --- |
| VPC | 1 | 10.20.0.0/16 |
| Public Subnet | 3 | NLB, NAT Gateway |
| Private-App Subnet | 3 | Control Plane, Worker, Redis |
| Private-Etcd Subnet | 3 | external etcd |
| Private-Data Subnet | 3 | RDS Subnet Group |
| Internet Gateway | 1 | Public 서브넷 아웃바운드 |
| NAT Gateway | 1 | Private 서브넷 아웃바운드 (AZ-a) |
| Route Table | 4 | 계층별 라우팅 |
| S3 Gateway Endpoint | 1 | S3 트래픽을 NAT 우회 |

### 보안

| 리소스 | 수량 | 역할 |
| --- | --- | --- |
| Security Group | 8 | public-nlb, internal-nlb, control-plane, etcd, worker, k8s-node, rds, redis |
| IAM Role | 1 | EC2 노드 공통 |
| 인스턴스 프로파일 | 1 | Role 을 EC2 에 부착 |

### 컴퓨트

| 리소스 | 수량 | 타입 | 역할 |
| --- | --- | --- | --- |
| Control Plane | 3 | t3.medium | kube-apiserver, scheduler, controller-manager |
| external etcd | 3 | t3.small | 클러스터 상태 저장 |
| Worker | 3 | t3.large | 애플리케이션 워크로드 |
| Redis | 1 | t3.small | 캐시, JWT 화이트리스트 |

### 데이터

| 리소스 | 수량 | 역할 |
| --- | --- | --- |
| RDS PostgreSQL | 1 | db.t4g.small, 18.6 |
| DB Subnet Group | 1 | Private-Data ×3 |
| DB Parameter Group | 1 | 커스텀 (현재 기본값 유지) |
| Secrets Manager 시크릿 | 1 | RDS 마스터 비밀번호 (AWS 관리) |
| SSM Parameter | 1 | Redis ACL 비밀번호 (SecureString) |

### 로드밸런서

| 리소스 | 수량 | 역할 |
| --- | --- | --- |
| Internal NLB | 1 | kubelet·kubectl → apiserver |
| Public NLB | 1 | CloudFront → Envoy Gateway |
| Target Group | 2 | tg-api (6443), tg-envoy (30080) |

### 엣지

| 리소스 | 수량 | 역할 |
| --- | --- | --- |
| Route53 Hosted Zone | 1 | re-used.store |
| Route53 레코드 | 7 | 서비스 5, ACM 검증 2 |
| ACM 인증서 | 2 | us-east-1 (CloudFront), ap-northeast-1 (NLB) |
| CloudFront Distribution | 1 | 캐싱, TLS 종단, WAF 연결 |
| WAF Web ACL | 1 | 관리형 룰 3개, Count 모드 |

### Terraform 외부

| 리소스 | 역할 |
| --- | --- |
| S3 버킷 `logssey-prod-s3-tfstate` | 상태 파일 저장. 수동 생성 |

---

## 콘솔 확인 위치

리전은 별도 표기가 없으면 **ap-northeast-1 (도쿄)** 다.

| 대상 | 콘솔 경로 |
| --- | --- |
| VPC, 서브넷, 라우팅 | VPC → Your VPCs / Subnets / Route tables |
| NAT Gateway | VPC → NAT gateways |
| S3 Endpoint | VPC → Endpoints |
| Security Group | VPC → Security groups |
| EC2 인스턴스 | EC2 → Instances |
| EBS 볼륨 | EC2 → Volumes |
| NLB, 타겟 그룹 | EC2 → Load balancers / Target groups |
| IAM Role | IAM → Roles → `logssey-prod-role-node` |
| RDS | RDS → Databases → `logssey-prod-rds` |
| RDS 파라미터 | RDS → Parameter groups → `logssey-prod-pg18` |
| Secrets Manager | Secrets Manager → `rds!db-...` |
| SSM Parameter | Systems Manager → Parameter Store |
| Route53 | Route 53 → Hosted zones → `re-used.store` |
| ACM (NLB용) | Certificate Manager (ap-northeast-1) |
| **ACM (CloudFront용)** | Certificate Manager **(us-east-1)** |
| CloudFront | CloudFront → Distributions |
| **WAF** | WAF & Shield → Web ACLs **(Global / us-east-1)** |

**CloudFront 와 WAF 는 us-east-1 에서 조회한다.**
CloudFront 용 ACM 인증서와 CLOUDFRONT scope 의 Web ACL 은
리전이 고정되어 있다.

### 상태 점검

```bash
cd terraform/environments/prod

# 노드
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=logssey" "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name]' \
  --output table

# RDS
aws rds describe-db-instances \
  --db-instance-identifier $(terraform output -raw rds_instance_id) \
  --region ap-northeast-1 \
  --query 'DBInstances[0].[DBInstanceStatus,EngineVersion]' --output text

# NLB 타겟
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw public_target_group_arn) \
  --region ap-northeast-1 \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table

# 외부 진입 경로
curl -sS -o /dev/null -w "%{http_code}\n" https://re-used.store/
```

---

## 상태 관리

### 상태 파일이란

Terraform은 자신이 만든 리소스의 정보를 `terraform.tfstate`에 기록한다.
다음 실행에서 이 파일을 기준으로 "무엇이 이미 있고 무엇을 만들어야 하는지"를 판단한다.

```
.tf 파일          이렇게 되어야 한다
tfstate           내가 만든 것은 이렇다
AWS 실제 상태      지금 이렇게 되어 있다
        |
        +--> 셋을 비교해 차이를 계산
```

| 비교 결과 | 동작 |
| --- | --- |
| .tf에 있고 state에 없음 | `+ create` |
| state에 있고 .tf에 없음 | `- destroy` |
| 둘 다 있으나 값이 다름 | `~ update` 또는 `-/+ replace` |
| state에 있으나 AWS에 없음 | 재생성 (콘솔에서 삭제된 경우) |

**상태 파일을 잃으면 Terraform이 인프라를 인식하지 못한다.**
`destroy`도 불가능해지고 리소스를 하나씩 `import`해야 한다.
이 때문에 S3에 저장하고 버전 관리를 켜둔다.

### 저장 위치

| 항목 | 값 |
| --- | --- |
| 버킷 | `logssey-prod-s3-tfstate` |
| 경로 | `prod/terraform.tfstate` |
| 잠금 파일 | `prod/terraform.tfstate.tflock` |
| 버전 관리 | 활성 (이전 버전 복구 가능) |

DynamoDB 잠금 테이블은 사용하지 않는다.
`dynamodb_table` 인자는 deprecated이며, Terraform 1.10부터 지원되는
S3 조건부 쓰기 기반 `use_lockfile = true`를 사용한다.

**상태 파일에는 민감 정보가 포함될 수 있다.**
RDS 마스터 비밀번호는 `manage_master_user_password` 로 AWS 가 관리해
상태 파일에 남지 않으나, 다른 리소스의 속성은 평문으로 기록된다.
노드 IAM Role 에 이 버킷에 대한 명시적 Deny 정책을 부착해
EC2 에서 접근할 수 없도록 한다. `docs/03-iam.md` 참조.

### 잠금 동작

`plan`과 `apply` 모두 잠금을 획득한다.
`plan`도 refresh 과정에서 상태를 갱신할 수 있기 때문이다.

| 명령 | 잠금 | 상태 쓰기 |
| --- | --- | --- |
| `init` / `fmt` / `validate` | 없음 | — |
| `plan` | 있음 | 안 함 |
| `apply` / `destroy` | 있음 | 함 |
| `output` | 없음 | — |

**두 사람이 동시에 실행하면**

```
A: terraform apply 시작
   -> S3에 terraform.tfstate.tflock 생성 (조건부 쓰기)
   -> 리소스 생성 진행

B: terraform plan 시작
   -> .tflock 생성 시도 -> 이미 존재
   -> 에러 후 종료

A: apply 완료
   -> 상태 파일 업로드
   -> .tflock 삭제

B: 재시도 -> 정상 진행
```

B가 보게 되는 에러

```
Error: Error acquiring the state lock
api error PreconditionFailed: At least one of the pre-conditions you specified did not hold

Lock Info:
  ID:        9ca30262-a33c-ae75-eb09-9b76db1f3f00
  Path:      logssey-prod-s3-tfstate/prod/terraform.tfstate
  Operation: OperationTypeApply
  Who:       jongmin@BOOK-H1JUJFRUUG
  Created:   2026-09-21 05:58:31
```

`Who`와 `Created`로 누가 언제부터 잡고 있는지 확인할 수 있다.

### 잠금이 남았을 때

정상 종료 시에는 자동으로 해제되지만, `Ctrl+C`나 네트워크 단절로
프로세스가 죽으면 `.tflock`이 남는다.

**반드시 락 보유자에게 확인한 뒤** 해제한다.
실행 중인 apply를 강제 해제하면 상태 파일이 깨질 수 있다.

```bash
terraform force-unlock <LOCK_ID>

# 해제 후 확인 — terraform.tfstate 만 남아야 한다
aws s3 ls s3://logssey-prod-s3-tfstate/prod/
```

### 잠금 범위

`key` 단위로 격리된다. 환경이 다르면 서로 막지 않는다.

```
prod/terraform.tfstate.tflock   -> prod 작업만 차단
dev/terraform.tfstate.tflock    -> dev 는 동시 실행 가능
```

로컬에서 실행하든 CI에서 실행하든 같은 S3 객체를 보므로
잠금은 실행 위치와 무관하게 공유된다.

---

## 태그 정책

provider 의 `default_tags` 로 모든 리소스에 자동 부착한다.

| 키 | 값 | 용도 |
| --- | --- | --- |
| Project | logssey | 프로젝트 식별 |
| Environment | prod | 환경 구분 |
| ManagedBy | terraform | 수동 생성 리소스와 구분 |
| Owner | tfvars 에서 지정 | 책임자 추적 |

리소스별로는 `Name` 태그만 추가한다.

**`default_tags` 와 같은 키를 리소스에서 다시 지정하면**
Terraform 이 매번 변경으로 감지해 plan 에 계속 나타난다.
리소스 태그는 여기와 겹치지 않는 키만 사용한다.

SG 개방 규칙에는 `Tier = T2-remove` 태그를 추가로 부착한다.
제거 대상을 콘솔과 CLI 에서 식별하기 위함이다. `docs/02-security.md` 참조.

provider 를 두 개 쓰므로 `default_tags` 도 각각 선언해야 한다.
us-east-1 provider 는 CloudFront 용 ACM 인증서와 WAF Web ACL 에 쓰인다.

태그로 리소스를 조회할 수 있다.

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=logssey" \
  --region ap-northeast-1
```

---

## 보안 모드

1차 구축과 조치 완료 상태를 변수 하나로 전환한다.

| 값 | 의미 |
| --- | --- |
| `permissive` | 1차 구축. 체인 규칙 + 개방 규칙을 함께 적용 (기본값) |
| `strict` | 조치 완료. 개방 규칙만 제거 |

```bash
terraform apply -var="security_mode=strict"
```

**permissive 상태에서는 체인 규칙이 맞는지 검증할 수 없다.**
개방 규칙이 대부분의 트래픽을 통과시키므로 누락이 있어도 드러나지 않는다.
strict 전환 후 주요 경로 점검이 필요하다.

상세는 `docs/02-security.md`, `docs/03-iam.md` 참조.

---

## 구성

| 항목 | 내용 |
| --- | --- |
| Cloud | AWS (ap-northeast-1) |
| IaC | Terraform |
| Kubernetes | 1.35.4 (Kubespray v2.31.0) |
| CNI | Cilium 1.19.3 (VXLAN, kube-proxy replacement) |
| Ingress | Envoy Gateway v1.9.1 (Gateway API v1.6.1) |
| 스토리지 | AWS EBS CSI Driver (gp3 기본 StorageClass) |
| 메트릭 | metrics-server |
| DB | RDS PostgreSQL 18.6 |
| 캐시 | Redis 7.0.15 (EC2) |
| CDN | CloudFront + WAF |
| 도메인 | re-used.store |

## 디렉터리

```
terraform/
  environments/prod/    루트 모듈. init/plan/apply 실행 위치
  modules/
    network/            VPC, 서브넷, 라우팅, NAT, Endpoint
    security/           Security Group, 규칙
    iam/                IAM Role, 인스턴스 프로파일
    compute/            EC2, user_data
    rds/                RDS, Subnet Group, 파라미터 그룹
    dns/                Route53 Hosted Zone, ACM 인증서
    lb/                 Internal NLB, Public NLB
    edge/               CloudFront, WAF, 서비스 레코드
kubespray/              클러스터 인벤토리 및 변수
k8s/
  platform/             애드온 Helm values, 매니페스트
docs/                   구현 명세
  concepts/             기술 개념과 선택 근거
  troubleshooting/      구축 중 문제 해결 기록
```

**엣지 계층은 세 모듈로 나뉜다.**
`dns → lb → edge` 순서로 의존하며, 순환 참조를 피하기 위한 구조다.
상세는 `docs/10-edge.md` 참조.

## 문서

### 구현 명세

| 파일 | 내용 |
| --- | --- |
| [01-network.md](docs/01-network.md) | VPC, 서브넷 CIDR, 라우팅 |
| [02-security.md](docs/02-security.md) | Security Group 체인, 개방 규칙 |
| [03-iam.md](docs/03-iam.md) | IAM Role, IMDS, 최소 권한 계획 |
| [04-compute.md](docs/04-compute.md) | 노드 스펙, 사설 IP, user_data |
| [05-loadbalancer.md](docs/05-loadbalancer.md) | NLB 구성, Client IP Preservation |
| [06-kubespray.md](docs/06-kubespray.md) | 클러스터 구축, Cilium 설정 |
| [07-ingress.md](docs/07-ingress.md) | 진입 경로, Envoy Gateway, NodePort 고정 |
| [08-rds.md](docs/08-rds.md) | RDS PostgreSQL, 백업, 비밀번호 관리 |
| [09-redis.md](docs/09-redis.md) | Redis EC2, ACL, 메모리·영속성 |
| [10-edge.md](docs/10-edge.md) | ACM, CloudFront, WAF, Route53 |

### 개념

기술이 무엇이고 왜 그것을 골랐는지 다룬다.
구축 중 막혔거나 선택 근거가 필요했던 영역만 기록한다.

| 파일 | 내용 |
| --- | --- |
| [concepts/](docs/concepts/) | 목록과 작성 기준 |
| [concepts/cni.md](docs/concepts/cni.md) | Pod 네트워킹, Overlay 와 Native routing, CNI 비교 |

### 절차

| 파일 | 내용 |
| --- | --- |
| [k8s/README.md](k8s/README.md) | 애드온 설치 절차와 검증 |
| [kubespray/README.md](kubespray/README.md) | 인벤토리 반영 절차 |

### 트러블슈팅

구축 중 발생한 문제와 진단 과정. 결론뿐 아니라 오판한 과정도 기록한다.

| # | 제목 | 원인 |
| --- | --- | --- |
| [README](docs/troubleshooting/) | 목록, 분류, 진단 참고 명령 | |
| [01](docs/troubleshooting/01-etcd-worker-certs.md) | 워커 노드 etcd 인증서 미생성 | Kubespray `gen_certs` 평가 순서 |
| [02](docs/troubleshooting/02-etcd-client-sg.md) | etcd 클러스터 헬스체크 실패 | SG — 멤버 간 2379 누락 |
| [03](docs/troubleshooting/03-cilium-cni-bin-permission.md) | Cilium mount-cgroup 실패 | `/opt/cni/bin` 소유자, `DAC_OVERRIDE` |
| [04](docs/troubleshooting/04-kube-proxy-ipvs-conflict.md) | Service 접속 불가 (병행 구성) | kube-proxy IPVS ↔ eBPF 충돌 |
| [05](docs/troubleshooting/05-apiserver-sg-kpr.md) | Service 접속 불가 (replacement) | SG — Worker → CP 6443 누락 |
| [06](docs/troubleshooting/06-kubelet-api-sg.md) | kubelet API 접근 불가 | SG — 10250 방향 누락 |
| [07](docs/troubleshooting/07-iptables-corruption-l7.md) | L7 NetworkPolicy 미동작 | iptables 직접 조작으로 Cilium 상태 손상 |
| [08](docs/troubleshooting/08-envoy-gateway-nodeport.md) | Envoy Gateway NodePort 고정 실패 | StrategicMerge 병합 키, DoNotSchedule 교착 |
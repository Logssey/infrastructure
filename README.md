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

**상태 파일에는 RDS·Redis 비밀번호가 평문으로 저장된다.**
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
    lb/                 Internal NLB, Public NLB
    edge/               Route53 Hosted Zone
kubespray/              클러스터 인벤토리 및 변수
k8s/
  platform/             애드온 Helm values, 매니페스트
docs/                   구현 명세
  troubleshooting/      구축 중 문제 해결 기록
```

## 문서

| 파일 | 내용 |
| --- | --- |
| [01-network.md](docs/01-network.md) | VPC, 서브넷 CIDR, 라우팅 |
| [02-security.md](docs/02-security.md) | Security Group 체인, 개방 규칙 |
| [03-iam.md](docs/03-iam.md) | IAM Role, IMDS, 최소 권한 계획 |
| [04-compute.md](docs/04-compute.md) | 노드 스펙, 사설 IP, user_data |
| [05-loadbalancer.md](docs/05-loadbalancer.md) | NLB 구성, Client IP Preservation |
| [06-kubespray.md](docs/06-kubespray.md) | 클러스터 구축, Cilium 설정 |
| [07-ingress.md](docs/07-ingress.md) | 진입 경로, Envoy Gateway, NodePort 고정 |
| [k8s/README.md](k8s/README.md) | 애드온 설치 절차와 검증 |
| [kubespray/README.md](kubespray/README.md) | 인벤토리 반영 절차 |
| [troubleshooting/](docs/troubleshooting/) | 구축 중 발생한 문제와 해결 과정 |
# 03. IAM 구현

> 설계 근거는 Notion [3. IAM/인증] 참조

## 범위

본 문서는 **EC2 노드용 인스턴스 프로파일**만 다룬다.
사람 계정(IAM User), GitHub Actions OIDC, Vault 관련 권한은 별도 단계에서 정의한다.

| 대상 | 방식 | 시점 |
| --- | --- | --- |
| EC2 노드 | IAM Role + 인스턴스 프로파일 | 본 문서 |
| 운영자 | IAM User + MFA | 계정 준비 시 완료 |
| GitHub Actions | IAM Role + OIDC | CI/CD 구축 시 |

## Role 구성

### 1차 구축 — 단일 Role

CP 3 · etcd 3 · Worker 3 · Redis 1, 총 10대에 동일한 Role을 부착한다.

| 리소스 | 이름 |
| --- | --- |
| IAM Role | logssey-prod-role-node |
| 인스턴스 프로파일 | logssey-prod-instance-profile-node |

EC2 에 Role 을 직접 부착할 수 없다. 인스턴스 프로파일로 감싸야 한다.

신뢰 관계는 `ec2.amazonaws.com` 만 허용한다.
다른 서비스나 계정이 이 Role 을 assume 할 수 없다.

### 부착 정책 (두 모드 공통)

| 정책 | 용도 | 실제 필요 대상 |
| --- | --- | --- |
| AmazonSSMManagedInstanceCore | SSM Session Manager 접속 | 전 노드 |
| AmazonEC2ContainerRegistryReadOnly | ECR 이미지 pull | Worker |
| AmazonEBSCSIDriverPolicy | EBS 볼륨 생성·연결·스냅샷 | Worker |

**SSM Core가 없으면 EC2에 접속할 방법이 없다.** 인바운드 포트를 열지 않는 구성이므로
SSM이 유일한 접근 경로다.

**EBS CSI 정책은 모드와 무관하게 유지한다.**
permissive 의 `AmazonEC2FullAccess` 로도 동작하나, strict 전환 시 해당 정책이
제거되면 PVC 프로비저닝이 중단되기 때문이다.

### permissive 추가 정책 (strict에서 제거)

| 정책 | 예상 finding | strict 전환 시 |
| --- | --- | --- |
| AmazonS3FullAccess | Overly permissive IAM policy | 버킷·Prefix 단위 정책으로 대체 |
| AmazonEC2FullAccess | IAM policy allows full access to service | 제거만 한다. 대체 불필요 |

`AmazonEC2FullAccess` 가 담당하던 EBS CSI 권한은 `AmazonEBSCSIDriverPolicy` 로
이미 분리되어 있다. 제거해도 동작에 영향이 없다.

`AmazonS3FullAccess` 는 이미지 버킷과 감사 버킷 접근을 대신하고 있으므로
제거 전에 대체 정책을 먼저 준비해야 한다.

### 상태 파일 버킷 보호 (모드 무관, 항상 적용)

`logssey-prod-s3-tfstate` 버킷에 대해 명시적 Deny 정책을 부착한다.

상태 파일에는 RDS·Redis 비밀번호가 평문으로 저장되므로 의도적 취약 설정의
범위에서 제외한다. IAM 평가에서 Deny는 Allow보다 우선하므로
`AmazonS3FullAccess`가 부착되어 있어도 이 버킷에는 접근할 수 없다.

| 정책 | 이름 | 적용 시점 |
| --- | --- | --- |
| Deny s3:* on tfstate | logssey-prod-deny-tfstate | permissive · strict 공통 |

## 구조적 한계 — IRSA 부재

**IRSA(IAM Roles for Service Accounts)** 는 EKS 가 제공하는 기능으로,
Kubernetes ServiceAccount 에 IAM Role 을 직접 연결한다.
Pod 마다 다른 권한을 부여할 수 있다.

self-managed 클러스터에는 이 기능이 없다.
OIDC Provider 를 직접 구성하면 가능하나, apiserver 의 서비스 계정 토큰을
외부에 노출하고 IAM 에 등록하는 작업이 필요하다.

**따라서 노드 위의 모든 Pod 가 노드 Role 의 권한을 동일하게 사용한다.**
EBS CSI Driver 가 볼륨을 만들 수 있다는 것은, 같은 노드의 다른 Pod 도
EC2 API 를 호출할 수 있다는 뜻이다.

Pod 단위 권한 분리가 필요해지면 IRSA 구성 또는 Pod Identity 대안을 검토한다.

## T2 조치 계획

### 역할별 Role 분리

| Role | 대상 | 권한 |
| --- | --- | --- |
| role-control-plane | CP 3 | SSM Core |
| role-etcd | etcd 3 | SSM Core, S3 백업 Prefix 쓰기 |
| role-worker | Worker 3 | SSM Core, ECR pull, S3 이미지 Prefix, EBS CSI |
| role-redis | Redis 1 | SSM Core |

CP와 Redis에 ECR·S3·EBS 권한을 줄 이유가 없다.

### 최소 권한 정책

S3 — 버킷과 Prefix 단위로 제한한다.

```
s3:GetObject, s3:PutObject
→ arn:aws:s3:::logssey-prod-s3-images/listings/*
```

EBS CSI — 관리형 정책 `AmazonEBSCSIDriverPolicy` 가 이미 최소 권한이다.

AWS 가 제공하는 `AmazonEBSCSIDriverPolicyV2` 는 드라이버용으로 태그된 볼륨과
스냅샷으로 범위를 더 좁힌 버전이다. 전환을 검토한다.

### IMDS 대응

**IMDS(Instance Metadata Service)** 는 EC2 인스턴스가 자신의 메타데이터와
IAM Role 자격증명을 조회하는 내부 엔드포인트다.
`169.254.169.254` 로 접근하며 인증 없이 호출된다.
AWS SDK 와 CLI 가 자격증명을 얻는 기본 경로다.

IRSA 가 없는 구성에서 Pod 가 침해되면 IMDS 를 호출해 노드 Role 의
자격증명을 탈취할 수 있다.

| 조치 | 내용 |
| --- | --- |
| IMDSv2 강제 | `http_tokens = "required"`. 토큰 없는 단순 GET 요청 차단 |
| hop limit 제한 | `http_put_response_hop_limit = 1`. 컨테이너에서 IMDS 도달 차단 |

IMDSv1 은 인증 없이 `GET /latest/meta-data/` 를 호출하면 응답한다.
SSRF 취약점이 있는 애플리케이션을 통해 외부에서 자격증명을 얻을 수 있다.
IMDSv2 는 PUT 으로 토큰을 먼저 받아야 하므로 단순 GET 기반 공격이 차단된다.

hop limit 은 IMDS 응답 패킷의 TTL 을 제한한다.
1 이면 호스트 네트워크에서만 도달하고, 컨테이너 네트워크를 한 홉 거치는
Pod 에서는 응답이 소멸한다.

1차 구축에서는 IMDSv1을 허용한다. 예상 finding: `EC2 instance allows IMDSv1`.
설정은 compute 모듈의 `metadata_options` 블록에 있다. `docs/04-compute.md` 참조.

## 확인

Role 에 부착된 정책 조회

```bash
aws iam list-attached-role-policies \
  --role-name logssey-prod-role-node \
  --query 'AttachedPolicies[].PolicyName' \
  --output table
```

인라인 정책 조회

```bash
aws iam list-role-policies \
  --role-name logssey-prod-role-node \
  --output text

aws iam get-role-policy \
  --role-name logssey-prod-role-node \
  --policy-name logssey-prod-deny-tfstate \
  --query 'PolicyDocument'
```

신뢰 관계 확인

```bash
aws iam get-role \
  --role-name logssey-prod-role-node \
  --query 'Role.AssumeRolePolicyDocument'
```

인스턴스 프로파일 확인

```bash
aws iam get-instance-profile \
  --instance-profile-name logssey-prod-instance-profile-node \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output text
```
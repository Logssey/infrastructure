# 03. IAM 구현

> 설계 근거는 Notion [3. IAM/인증] 참조

## 범위

본 문서는 **EC2 노드용 인스턴스 프로파일**만 다룬다.
사람 계정(IAM User), GitHub Actions OIDC, Vault 관련 권한은 별도 단계에서 정의한다.

| 대상 | 방식 | 시점 |
| --- | --- | --- |
| EC2 노드 | IAM Role + 인스턴스 프로파일 | 본 문서 |
| 운영자 | IAM User + MFA | 계정 준비 시 완료 |
| GitHub Actions | IAM Role + OIDC | 스프린트 5 |

## Role 구성

### 1차 구축 — 단일 Role

CP 3 · etcd 3 · Worker 3 · Redis 1, 총 10대에 동일한 Role을 부착한다.

| 리소스 | 이름 |
| --- | --- |
| IAM Role | logssey-prod-role-node |
| 인스턴스 프로파일 | logssey-prod-instance-profile-node |

### 부착 정책 (두 모드 공통)

| 정책 | 용도 | 필요 대상 |
| --- | --- | --- |
| AmazonSSMManagedInstanceCore | SSM Session Manager 접속 | 전 노드 |
| AmazonEC2ContainerRegistryReadOnly | ECR 이미지 pull | Worker |

**SSM Core가 없으면 EC2에 접속할 방법이 없다.** 인바운드 포트를 열지 않는 구성이므로
SSM이 유일한 접근 경로다.

### permissive 추가 정책 (strict에서 제거)

| 정책 | 실제 필요 범위 | 예상 finding |
| --- | --- | --- |
| AmazonS3FullAccess | 이미지 버킷 Get/Put, 감사 버킷 Put | Overly permissive IAM policy |
| AmazonEC2FullAccess | EBS CSI Driver 볼륨 생성·연결·삭제 | IAM policy allows full access to service |

### 상태 파일 버킷 보호 (모드 무관, 항상 적용)

`logssey-prod-s3-tfstate` 버킷에 대해 명시적 Deny 정책을 부착한다.

상태 파일에는 RDS·Redis 비밀번호가 평문으로 저장되므로 의도적 취약 설정의
범위에서 제외한다. IAM 평가에서 Deny는 Allow보다 우선하므로
`AmazonS3FullAccess`가 부착되어 있어도 이 버킷에는 접근할 수 없다.

| 정책 | 이름 | 적용 시점 |
| --- | --- | --- |
| Deny s3:* on tfstate | logssey-prod-deny-tfstate | permissive · strict 공통 |

## T2 조치 계획

### 역할별 Role 분리

| Role | 대상 | 권한 |
| --- | --- | --- |
| role-control-plane | CP 3 | SSM Core |
| role-etcd | etcd 3 | SSM Core, S3 백업 Prefix 쓰기 |
| role-worker | Worker 3 | SSM Core, ECR pull, S3 이미지 Prefix, EBS CSI |
| role-redis | Redis 1 | SSM Core |

CP와 Redis에 ECR·S3 권한을 줄 이유가 없다.

### 최소 권한 정책 예시

S3 — 버킷과 Prefix 단위로 제한한다.

s3:GetObject, s3:PutObject
→ arn:aws:s3:::logssey-prod-s3-images/listings/*

EBS CSI — 볼륨 조작에 필요한 액션만 허용한다.

ec2:CreateVolume, ec2:DeleteVolume, ec2:AttachVolume,
ec2:DetachVolume, ec2:DescribeVolumes, ec2:CreateSnapshot


### IMDS 대응

Self-managed 클러스터에는 IRSA가 없어 Pod가 노드 Role의 권한을 상속한다.
Pod가 침해되면 IMDS를 통해 자격증명을 탈취할 수 있다.

| 조치 | 내용 |
| --- | --- |
| IMDSv2 강제 | `http_tokens = "required"`. IMDSv1의 단순 GET 요청 차단 |
| hop limit 제한 | `http_put_response_hop_limit = 1`. 컨테이너에서 IMDS 도달 차단 |

1차 구축에서는 IMDSv1을 허용한다. 예상 finding: `EC2 instance allows IMDSv1`.

## 확인

```bash
# Role에 부착된 정책 조회
aws iam list-attached-role-policies \
  --role-name logssey-prod-role-node \
  --query 'AttachedPolicies[].PolicyName' \
  --output table

# 인스턴스 프로파일 확인
aws iam get-instance-profile \
  --instance-profile-name logssey-prod-instance-profile-node \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output text
```
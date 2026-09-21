# Logssey · Infrastructure

Re:Used 중고거래 플랫폼의 클라우드 인프라 코드.

## 사전 요구사항

| 도구 | 버전 |
| --- | --- |
| Terraform | >= 1.10 |
| AWS CLI | v2 |

## 시작하기

```bash
cd terraform/environments/prod

cp example.tfvars terraform.tfvars   # 값 채우기
terraform init
terraform plan
terraform apply
```

## 상태 관리

상태 파일은 S3에 저장하고 S3 네이티브 잠금(`use_lockfile`)을 사용한다.

| 항목 | 값 |
| --- | --- |
| 버킷 | `logssey-prod-s3-tfstate` |
| 경로 | `prod/terraform.tfstate` |
| 잠금 | `prod/terraform.tfstate.tflock` (apply 중에만 존재) |

`apply` 시작 시 `.tflock` 객체가 생성되고 종료 시 삭제된다. 다른 사람이 동시에 실행하면 에러가 발생한다.
- 정상 종료되면 자동으로 해제되지만, `Ctrl+C` 등으로 강제 종료하면 잠금이 남는다. 이때는 락 보유자를 확인한 뒤 해제한다.
```bash
terraform force-unlock <LOCK_ID>
```

## 구성

| 항목 | 내용 |
| --- | --- |
| Cloud | AWS (ap-northeast-1) |
| IaC | Terraform |
| Kubernetes | Kubespray (Self-managed) |
| CNI | Cilium |
| Ingress | Envoy Gateway |

## 디렉토리
- terraform/ AWS 리소스 정의
- kubespray/ 클러스터 인벤토리 및 변수
- docs/ 설계 문서
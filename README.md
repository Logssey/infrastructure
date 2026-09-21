# Logssey · Infrastructure

Re:Used 중고거래 플랫폼의 클라우드 인프라 코드.

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
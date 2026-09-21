# 01. 네트워크 구현

> 설계 근거는 Notion [1. 네트워크] 참조

## 확정값

리전: ap-northeast-1
AZ:   1a / 1c / 1d

### VPC

| 리소스 | 이름 | CIDR |
| --- | --- | --- |
| VPC | logssey-prod-vpc | 10.20.0.0/16 |

### Subnet (12개)

| 계층 | AZ | 이름 | CIDR |
| --- | --- | --- | --- |
| Public | 1a | logssey-prod-subnet-public-a | 10.20.0.0/24 |
| Public | 1c | logssey-prod-subnet-public-c | 10.20.1.0/24 |
| Public | 1d | logssey-prod-subnet-public-d | 10.20.2.0/24 |
| App | 1a | logssey-prod-subnet-app-a | 10.20.10.0/24 |
| App | 1c | logssey-prod-subnet-app-c | 10.20.11.0/24 |
| App | 1d | logssey-prod-subnet-app-d | 10.20.12.0/24 |
| Etcd | 1a | logssey-prod-subnet-etcd-a | 10.20.20.0/24 |
| Etcd | 1c | logssey-prod-subnet-etcd-c | 10.20.21.0/24 |
| Etcd | 1d | logssey-prod-subnet-etcd-d | 10.20.22.0/24 |
| Data | 1a | logssey-prod-subnet-data-a | 10.20.30.0/24 |
| Data | 1c | logssey-prod-subnet-data-c | 10.20.31.0/24 |
| Data | 1d | logssey-prod-subnet-data-d | 10.20.32.0/24 |

### Route Table (4개)

| 이름 | 연결 Subnet | 경로 |
| --- | --- | --- |
| logssey-prod-rt-public | Public ×3 | 0.0.0.0/0 → IGW |
| logssey-prod-rt-app | App ×3 | 0.0.0.0/0 → NAT-a, S3 PL → GWE |
| logssey-prod-rt-etcd | Etcd ×3 | 0.0.0.0/0 → NAT-a, S3 PL → GWE |
| logssey-prod-rt-data | Data ×3 | local only |

### 기타

| 리소스 | 이름 | 배치 |
| --- | --- | --- |
| Internet Gateway | logssey-prod-igw | — |
| NAT Gateway | logssey-prod-nat-a | Public-1a |
| EIP (NAT용) | logssey-prod-eip-nat-a | — |
| S3 Gateway Endpoint | logssey-prod-vpce-s3 | rt-app, rt-etcd |

### Kubernetes 예약 대역

| 용도 | CIDR | 비고 |
| --- | --- | --- |
| Pod | 10.244.0.0/16 | VPC 외부 대역. Cilium VXLAN |
| Service | 10.96.0.0/16 | 클러스터 내부 전용 |

### 확장 예약

10.20.40.0/21 이후 미사용
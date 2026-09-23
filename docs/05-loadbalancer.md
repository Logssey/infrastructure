# 05. 로드밸런서 구현

> 설계 근거는 Notion [1. 네트워크 - Load Balancer 설정] 참조

## 구성

NLB 는 각 1대다. 지정한 서브넷마다 ENI 를 하나씩 생성한다.

| 이름 | 유형 | 배치 | 용도 |
| --- | --- | --- | --- |
| logssey-prod-nlb-internal-api | Internal NLB | Private-App ×3 | kubelet·kubectl → kube-apiserver |
| logssey-prod-nlb-public | Internet-facing NLB | Public ×3 | CloudFront → Envoy Gateway |

## Internal API NLB

| 항목 | 값 |
| --- | --- |
| Scheme | internal |
| Subnet | Private-App ×3 |
| SG | sg-internal-nlb |
| Listener | TCP 6443 |
| Target Group | logssey-prod-tg-api, TCP 6443, instance 타입 |
| Target | Control Plane ×3 |
| Cross-Zone LB | 활성 |

### Client IP Preservation 비활성화 — 필수

Control Plane 노드 자신도 Internal NLB를 경유해 apiserver를 호출한다.

활성 상태에서는 NLB 가 클라이언트 IP 를 보존한 채 타겟에 전달한다.
요청이 발신 노드 자신에게 라우팅되면 출발지와 목적지가 같아져
TCP 연결이 성립하지 않는다. (hairpin)

**3대 중 1대에 걸릴 때만 발생하므로 간헐적 타임아웃으로 나타난다.**
정상 동작과 섞여서 원인 추적이 매우 어렵다.
Kubespray + NLB 조합의 대표적 장애 사례다.

## Public NLB

| 항목 | 값 |
| --- | --- |
| Scheme | internet-facing |
| Subnet | Public ×3 |
| SG | sg-public-nlb |
| Listener | TCP 80 |
| Target Group | logssey-prod-tg-envoy, TCP 30080, instance 타입 |
| Target | Worker ×3 |
| Cross-Zone LB | 활성 |

### TLS 리스너

CloudFront는 Custom Origin에 HTTPS로 연결할 때 오리진 도메인에 대한
퍼블릭 신뢰 인증서를 요구한다.
ACM 발급에는 도메인 네임서버 전파가 선행되므로 현재는 TCP 80 리스너만 구성한다.

ACM 인증서 발급 후 같은 NLB 에 TLS 443 리스너를 추가한다.
리스너 추가는 NLB 재생성을 유발하지 않는다.

| 도메인 | 연결 대상 |
| --- | --- |
| re-used.store | CloudFront |
| origin.re-used.store | Public NLB (ACM 인증서 대상) |

### Client IP Preservation 비활성화 — 필수

활성 상태에서는 Worker Node가 보는 출발지 IP가 NLB가 아니라
원래 클라이언트(CloudFront) IP가 된다.
이 상태에서는 `sg-public-nlb → sg-worker` 형태의 SG 참조 규칙이 동작하지 않는다.

실제 클라이언트 IP는 CloudFront가 `X-Forwarded-For` 헤더로 전달하므로
Envoy Gateway에서 읽는다.

이 결정은 Envoy 쪽 설정과 연결된다.
Client IP 보존이 필요 없으므로 Envoy Service 의 `externalTrafficPolicy` 를
`Cluster` 로 두어 모든 워커 노드가 NLB 타겟으로 healthy 를 유지한다.
`docs/07-ingress.md` 참조.

## NodePort 값 공유

Envoy Gateway 의 NodePort 는 세 곳에서 같은 값을 사용한다.

| 위치 | 정의 |
| --- | --- |
| `terraform/environments/prod/variables.tf` | `envoy_node_port` 변수 (기준값) |
| security 모듈 SG 2번 규칙 | 변수로 전달받음 |
| `k8s/platform/envoy-gateway/envoyproxy.yaml` | `nodePort` 에 수동 지정 |

Terraform 두 곳은 루트 변수 하나를 공유하므로 자동으로 일치한다.

**Kubernetes 매니페스트는 Terraform 이 관리하지 않으므로 수동으로 맞춰야 한다.**
클러스터 리소스는 향후 Argo CD 가 담당할 영역이며,
Terraform 이 클러스터 내부까지 관리하면 소유 주체가 섞인다.
양쪽 주석에 상호 참조를 남겨 변경 시 함께 수정하도록 한다.

값이 어긋나면 NLB 타겟이 전부 unhealthy 가 되고 외부 접근이 차단된다.

## Security Group 지정 — 생성 시점 필수

NLB의 Security Group은 **생성 시점에만 지정할 수 있다.**
SG 없이 생성하면 이후 추가가 불가능하며 NLB를 재생성해야 한다.

연결된 SG의 규칙 변경이나 SG 교체는 생성 후에도 가능하다.

ALB와 달리 NLB의 SG 지원은 비교적 최근에 추가된 기능이라
오래된 예제에는 SG가 없는 경우가 많다.

## 헬스체크

두 NLB 공통.

| 항목 | 값 |
| --- | --- |
| 프로토콜 | TCP |
| 포트 | traffic-port |
| 간격 | 10초 |
| 정상 임계 | 3 |
| 비정상 임계 | 3 |

간격 10초 × 임계 3회이므로 상태 전환에 약 30초가 걸린다.
노드 재부팅이나 Pod 롤링 시 이 시간만큼 타겟이 빠졌다가 복귀한다.

**타겟이 healthy 가 되는 시점.**

| 타겟 그룹 | 조건 |
| --- | --- |
| logssey-prod-tg-api (6443) | Kubespray 완료 후 |
| logssey-prod-tg-envoy (30080) | Envoy Gateway 설치 후 |

각 컴포넌트를 설치하기 전에는 unhealthy 가 정상이다.
포트에서 응답하는 프로세스가 없기 때문이다.

## Cross-Zone Load Balancing

두 NLB 모두 활성화한다.

NLB는 기본적으로 비활성이라, 특정 AZ의 타겟이 전부 unhealthy면
해당 AZ로 들어온 요청이 실패한다. AZ마다 노드가 1대씩이므로
한 대만 죽어도 해당 AZ 트래픽이 전부 실패한다.

AZ 간 데이터 전송료가 발생하나 트래픽 규모상 무시할 수준이다.

## 비용

| 항목 | 단가 | 월 (USD) |
| --- | --- | --- |
| Internal NLB | $0.0285/hr | 20.81 |
| Public NLB | $0.0285/hr | 20.81 |
| 퍼블릭 IPv4 3개 (Public NLB) | $0.005/hr | 10.95 |
| **합계** | | **52.57** |

도쿄 리전 기준, 730시간 환산. 2026-09 시점 요금이다.

**NLB 는 시간 요금 외에 NLCU 요금이 별도로 부과된다.**
신규 연결 수, 활성 연결 수, 처리 바이트, 규칙 평가 중 가장 큰 값을 기준으로
시간당 $0.006 가 과금된다. 트래픽이 없는 현재는 최소 사용량만 발생한다.

Public NLB는 AZ마다 ENI를 하나씩 갖고 각각 퍼블릭 IP를 할당받는다.
Internal NLB는 사설 IP만 사용하므로 IP 과금이 없다.

실제 청구액은 Cost Explorer 에서 확인한다.

## 확인

NLB 목록

```bash
aws elbv2 describe-load-balancers \
  --region ap-northeast-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName, `logssey`)].[LoadBalancerName,Scheme,State.Code,DNSName]' \
  --output table
```

타겟 그룹 ARN 조회

```bash
aws elbv2 describe-target-groups \
  --region ap-northeast-1 \
  --query 'TargetGroups[?contains(TargetGroupName, `logssey`)].[TargetGroupName,Port,TargetGroupArn]' \
  --output table
```

타겟 상태

```bash
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --region ap-northeast-1 \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' \
  --output table
```

Client IP Preservation 확인 — false 여야 한다

```bash
aws elbv2 describe-target-group-attributes \
  --target-group-arn <TG_ARN> \
  --region ap-northeast-1 \
  --query "Attributes[?Key=='preserve_client_ip'].[Key,Value]" \
  --output table
```

Public NLB 의 AZ 별 IP 확인

```bash
aws elbv2 describe-load-balancers \
  --names logssey-prod-nlb-public \
  --region ap-northeast-1 \
  --query 'LoadBalancers[0].AvailabilityZones[].[ZoneName,SubnetId]' \
  --output table
```

## 생성 결과 (2026-09-21)

| NLB | DNS 이름 |
| --- | --- |
| Internal API | logssey-prod-nlb-internal-api-5201b55cdbb1d44e.elb.ap-northeast-1.amazonaws.com |
| Public | logssey-prod-nlb-public-a37c39e077808af2.elb.ap-northeast-1.amazonaws.com |

Internal API DNS는 Kubespray inventory의 `loadbalancer_apiserver.address`에 지정한다.

```bash
terraform output internal_api_dns_name
terraform output public_nlb_dns_name
```
# 05. 로드밸런서 구현

> 설계 근거는 Notion [1. 네트워크 - Load Balancer 설정] 참조

## 구성

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
| Target Group | TCP 6443, instance 타입 |
| Target | Control Plane ×3 |
| Cross-Zone LB | 활성 |

### Client IP Preservation 비활성화 — 필수

Control Plane 노드 자신도 Internal NLB를 경유해 apiserver를 호출한다.
활성 상태에서 NLB가 요청을 자기 자신에게 라우팅하면 출발지와 목적지가
동일 노드가 되어 패킷이 드롭된다. (hairpin 문제)

증상이 간헐적 타임아웃으로 나타나 원인 추적이 매우 어렵다.
Kubespray + NLB 조합의 대표적 장애 사례다.

## Public NLB

| 항목 | 값 |
| --- | --- |
| Scheme | internet-facing |
| Subnet | Public ×3 |
| SG | sg-public-nlb |
| Listener | TCP 80 (1차) |
| Target Group | TCP 30080, instance 타입 |
| Target | Worker ×3 |
| Cross-Zone LB | 활성 |

### TLS 리스너는 스프린트 3에서 추가

CloudFront는 Custom Origin에 HTTPS로 연결할 때 오리진 도메인에 대한
퍼블릭 신뢰 인증서를 요구한다. ACM 발급에는 도메인 네임서버 전파가
선행되므로 1차 구축에서는 TCP 80 리스너만 구성한다.

같은 NLB에 리스너를 추가하는 작업이므로 재생성은 발생하지 않는다.

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

## Security Group 지정 — 생성 시점 필수

NLB의 Security Group은 **생성 시점에만 지정할 수 있다.**
SG 없이 생성하면 이후 추가가 불가능하며 NLB를 재생성해야 한다.

(연결된 SG의 규칙 변경이나 SG 교체는 생성 후에도 가능하다.)

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

**구축 초기에는 두 타겟 그룹 모두 unhealthy가 정상이다.**

| 타겟 그룹 | healthy 시점 |
| --- | --- |
| Internal API (6443) | Kubespray 완료 후 |
| Public (30080) | Envoy Gateway 설치 후 |

## Cross-Zone Load Balancing

두 NLB 모두 활성화한다.

NLB는 기본적으로 비활성이라, 특정 AZ의 타겟이 전부 unhealthy면
해당 AZ로 들어온 요청이 실패한다. AZ마다 노드가 1대씩이므로
한 대만 죽어도 해당 AZ 트래픽이 전부 실패한다.

AZ 간 데이터 전송료가 발생하나 트래픽 규모상 무시할 수준이다.

## 비용

| 항목 | 월 (USD) |
| --- | --- |
| Internal NLB | 20.81 |
| Public NLB | 20.81 |
| 퍼블릭 IPv4 3개 (Public NLB) | 10.95 |
| **합계** | **52.57** |

Public NLB는 AZ마다 ENI를 하나씩 갖고 각각 퍼블릭 IP를 할당받는다.
Internal NLB는 사설 IP만 사용하므로 IP 과금이 없다.

## 확인

```bash
# NLB 목록
aws elbv2 describe-load-balancers \
  --region ap-northeast-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName, `logssey`)].[LoadBalancerName,Scheme,State.Code,DNSName]' \
  --output table

# 타겟 그룹 ARN 조회
aws elbv2 describe-target-groups \
  --region ap-northeast-1 \
  --query 'TargetGroups[?contains(TargetGroupName, `logssey`)].[TargetGroupName,Port,TargetGroupArn]' \
  --output table

# 타겟 상태
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --region ap-northeast-1 \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' \
  --output table

# Client IP Preservation 확인 — false 여야 한다
aws elbv2 describe-target-group-attributes \
  --target-group-arn <TG_ARN> \
  --region ap-northeast-1 \
  --query "Attributes[?Key=='preserve_client_ip'].[Key,Value]" \
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
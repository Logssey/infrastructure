# 07. 진입 경로 — Envoy Gateway

> 설계 근거는 Notion [1. 네트워크 - 진입 경로] 참조

## 전체 경로

```
클라이언트
   ↓ HTTPS 443
CloudFront                         WAF 연결, 캐싱
   ↓ HTTPS 443 (origin.re-used.store)
Public NLB                         Terraform 관리
   ↓ TCP 30080
Worker NodePort                    Envoy Gateway Service
   ↓
Envoy Proxy                        Gateway API 구현체
   ↓ HTTPRoute
Backend Service                    api / websocket / frontend
```

각 구간의 담당 주체가 다르다.

| 구간 | 관리 |
| --- | --- |
| CloudFront, ACM, WAF | Terraform (`modules/edge`) |
| Public NLB, 타겟 그룹, SG | Terraform (`modules/lb`, `modules/security`) |
| NodePort ~ Backend | Kubernetes 매니페스트 (`k8s/platform/envoy-gateway`) |

## 버전

| 항목 | 값 |
| --- | --- |
| Envoy Gateway | v1.9.1 |
| Gateway API | v1.6.1 (Envoy Gateway 번들) |
| Kubernetes | 1.35.4 |

Gateway API 는 최근 5개 Kubernetes 마이너 버전을 지원하며 v1.1 이후
Kubernetes 1.26 이상을 요구한다. 본 환경은 지원 범위 내에 있다.

Envoy Gateway 차트가 호환되는 Gateway API CRD 를 함께 설치하므로
버전 조합이 검증된 상태로 유지된다.

### Gateway API v1.6 변경 사항

| 항목 | 내용 |
| --- | --- |
| TCPRoute·UDPRoute | Standard 채널로 승격, v1 GA |
| 실험 리소스 | `gateway.networking.x-k8s.io` 그룹으로 분리, `X` 접두사 |
| listener 검증 | 강화됨. 기존 매니페스트 이관 시 확인 필요 |

본 환경은 신규 구축이며 HTTPRoute 만 사용하므로 영향이 없다.

## Ingress 가 아닌 Gateway API 를 선택한 이유

2026년 3월 Ingress NGINX 가 은퇴했다. 더 이상 버그 수정과 보안 패치가
제공되지 않으며, Gateway API 또는 서드파티 컨트롤러로의 마이그레이션이
권장된다.

Gateway API 는 역할 분리가 명확하다.

| 리소스 | 소유 |
| --- | --- |
| GatewayClass | 클러스터 관리자 |
| Gateway | 플랫폼 팀 |
| HTTPRoute | 애플리케이션 팀 |

Ingress 는 어노테이션으로 구현체별 기능을 확장해 이식성이 낮았으나,
Gateway API 는 표준 필드로 대부분을 표현한다.

## NodePort 30080 고정

### 왜 고정하는가

Public NLB 타겟 그룹이 포트를 하나 지정해야 한다.
Terraform 으로 30080 을 지정해 생성했고, SG 2번 규칙도 같은 포트다.

```
sg-public-nlb → sg-worker : TCP 30080
```

Kubernetes 가 NodePort 를 임의 배정하면(30000~32767) 그때마다
Terraform 을 수정해야 한다. Gateway 를 재생성할 때마다 포트가 바뀔 수 있어
인프라와 워크로드가 서로를 기다리는 상태가 된다.

### 고정 방법

`EnvoyProxy` CRD 로 Envoy Gateway 가 생성하는 Service 를 커스터마이즈한다.
`GatewayClass` 또는 `Gateway` 의 `parametersRef` 로 연결한다.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
        patch:
          type: StrategicMerge
          value:
            spec:
              ports:
                - name: <포트 이름>
                  nodePort: 30080
```

**`EnvoyProxy` 는 Gateway 보다 먼저 생성한다.** 나중에 연결하면
Service 가 재생성되며 일시적으로 트래픽이 끊긴다.

패치의 포트 이름은 Envoy Gateway 가 생성하는 Service 의 실제 이름과
일치해야 한다. 이름이 어긋나면 패치가 조용히 무시되므로,
Gateway 생성 후 Service 를 확인하고 값을 채운다.

### 대안 — AWS Load Balancer Controller

Service 를 `type: LoadBalancer` 로 두면 컨트롤러가 NLB 를 자동 생성한다.
EKS 에서 일반적인 방식이다.

| 항목 | 현재 방식 | LB Controller |
| --- | --- | --- |
| NLB 생성 | Terraform | 컨트롤러 |
| 타겟 등록 | Terraform | 컨트롤러 |
| 추가 설치 | 없음 | 컨트롤러 + IAM |
| 상태 관리 | Terraform 단일 | 이원화 |

**채택하지 않았다.**

Public NLB 를 이미 Terraform 으로 구축하고 검증했다. 

그리고 인프라 리소스를 Terraform 이 소유한다는 원칙이 설계 전반에 일관된다.
컨트롤러가 LB 를 만들면 Terraform 상태 밖의 AWS 리소스가 생겨
관리 주체가 둘로 나뉜다.

## Path 기반 라우팅

단일 도메인으로 서비스하며 CloudFront Behavior 와 HTTPRoute 가
같은 경로 규칙을 공유한다.

| Path | 백엔드 | CloudFront 캐싱 |
| --- | --- | --- |
| `/api/*` | api-svc | 비활성 |
| `/socket.io/*` | websocket-svc | 비활성, Upgrade 헤더 전달 |
| `/assets/*` | frontend-svc | 활성 (장기) |
| `*` | frontend-svc | 활성 (단기) |

단일 도메인이므로 CORS 설정이 불필요하고 Refresh Token 쿠키 처리가 단순해진다.

HTTPRoute 는 애플리케이션 배포 시점에 정의한다. 1차 구축에서는
테스트용 백엔드로 경로가 동작하는지만 확인한다.

## TLS 종단

| 구간 | 처리 |
| --- | --- |
| 클라이언트 → CloudFront | ACM (us-east-1) |
| CloudFront → Public NLB | ACM (ap-northeast-1), `origin.re-used.store` |
| NLB → Envoy | 평문. VPC 내부 구간 |

Envoy Gateway 는 TLS 를 종단하지 않는다. 클러스터 내부 구간이며
NLB 가 이미 복호화한 트래픽을 받는다.

CloudFront 가 전달하는 `X-Forwarded-For` 로 실제 클라이언트 IP 를 식별한다.
Public NLB 의 Client IP Preservation 이 비활성이므로
Envoy 가 보는 출발지 IP 는 NLB 주소다.

## Client IP Preservation 과의 관계

`docs/05-loadbalancer.md` 에 기록한 대로 Public NLB 는
Client IP Preservation 을 비활성화했다.

활성 상태에서는 Worker Node 가 보는 출발지가 CloudFront IP 가 되어
`sg-public-nlb → sg-worker` SG 참조 규칙이 동작하지 않는다.

Envoy Gateway 에서 실제 클라이언트 IP 가 필요하면
`ClientTrafficPolicy` 로 XFF 신뢰 홉 수를 설정한다.

## 미결정 사항

| 항목 | 결정 시점 |
| --- | --- |
| HTTPRoute 세부 정의 | 애플리케이션 배포 시 |
| `ClientTrafficPolicy` XFF 설정 | CloudFront 연결 후 |
| Envoy Proxy 리소스 요청·제한 | 부하 테스트 후 |
| 다중 Gateway 여부 | 현재 단일 Gateway |
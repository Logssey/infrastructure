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
Envoy Proxy                        Worker 3대에 각 1 Pod
   ↓ HTTPRoute
Backend Service                    api / websocket / frontend
```

각 구간의 담당 주체가 다르다.

| 구간 | 관리 |
| --- | --- |
| CloudFront, ACM, WAF | Terraform (`modules/edge`, 추후 추가) |
| Route53 Hosted Zone | Terraform (`modules/edge`) |
| Public NLB, 타겟 그룹, SG | Terraform (`modules/lb`, `modules/security`) |
| NodePort ~ Backend | Kubernetes 매니페스트 (`k8s/platform/envoy-gateway`) |

## 버전

| 항목 | 값 |
| --- | --- |
| Envoy Gateway | v1.9.1 |
| Gateway API | v1.6.1 (Envoy Gateway 번들) |
| Envoy Proxy | v1.39.1 |
| Kubernetes | 1.35.4 |

Gateway API 는 최근 5개 Kubernetes 마이너 버전을 지원하며 v1.1 이후
Kubernetes 1.26 이상을 요구한다. 본 환경은 지원 범위 내에 있다.

Envoy Gateway 차트가 호환되는 Gateway API CRD 를 함께 설치하므로
버전 조합이 검증된 상태로 유지된다. Kubespray 의 `gateway_api_enabled` 는
`false` 로 두어 CRD 관리 주체를 하나로 유지한다.

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

## 컨트롤플레인과 데이터플레인

Envoy Gateway 는 두 계층으로 나뉜다.

| 계층 | Deployment | 역할 |
| --- | --- | --- |
| 컨트롤플레인 | `envoy-gateway` | Gateway·HTTPRoute 를 감시해 Envoy 설정 생성 |
| 데이터플레인 | `envoy-envoy-gateway-system-eg-*` | 실제 트래픽 처리 |

데이터플레인 Deployment 는 Gateway 생성 시 컨트롤플레인이 만든다.
직접 정의하지 않고 `EnvoyProxy` CRD 로 설정한다.

**컨트롤플레인이 중단되어도 기존 Envoy 는 계속 동작한다.**
다만 Gateway 나 HTTPRoute 변경이 반영되지 않는다.
설정 변경이 막히는 상황을 피하기 위해 replica 2 로 운영한다.

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

이 값은 Terraform 의 `envoy_node_port` 변수, SG 2번 규칙,
`envoyproxy.yaml` 세 곳이 공유한다. 상세는 `docs/05-loadbalancer.md` 참조.

### 고정 방법

`EnvoyProxy` CRD 로 Envoy Gateway 가 생성하는 Service 를 커스터마이즈하고,
`GatewayClass` 의 `parametersRef` 로 연결한다.

```yaml
envoyService:
  type: NodePort
  externalTrafficPolicy: Cluster
  patch:
    type: StrategicMerge
    value:
      spec:
        ports:
          - port: 80
            name: http-80
            nodePort: 30080
```

**`EnvoyProxy` 는 Gateway 보다 먼저 생성한다.** 나중에 연결하면
Service 가 재생성되며 일시적으로 트래픽이 끊긴다.

패치 작성 시 주의할 점이 두 가지다.
상세는 [troubleshooting/08](troubleshooting/08-envoy-gateway-nodeport.md) 참조.

| 항목 | 내용 |
| --- | --- |
| 병합 키 | Service.ports 의 StrategicMerge 병합 키는 `port` 다. `name` 만 지정하면 인프라 생성이 실패한다 |
| 포트 이름 | 리스너 이름이 아니라 `http-<port>` 형식이다 |

### externalTrafficPolicy

기본값 `Local` 은 Envoy Pod 가 있는 노드만 응답한다.
Pod 가 3개 미만이거나 롤링 업데이트 중이면 NLB 타겟 일부가 unhealthy 로 빠진다.

`Cluster` 로 변경했다.

| 값 | 동작 | 클라이언트 IP |
| --- | --- | --- |
| Local | Pod 가 있는 노드만 응답 | 보존 |
| **Cluster** | 모든 노드가 응답, 필요 시 전달 | 보존 안 됨 |

Public NLB 의 Client IP Preservation 을 이미 비활성화했고 실제 클라이언트
IP 는 CloudFront 의 `X-Forwarded-For` 로 받으므로 `Local` 을 유지할 이유가 없다.

`Cluster` 는 롤링 업데이트 중에도 NLB 타겟 3대가 healthy 를 유지한다.

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

Public NLB 를 이미 Terraform 으로 구축하고 검증했다. 컨트롤러 방식으로
전환하면 CloudFront 연결 구성까지 영향을 받는다.

그리고 인프라 리소스를 Terraform 이 소유한다는 원칙이 설계 전반에 일관된다.
컨트롤러가 LB 를 만들면 Terraform 상태 밖의 AWS 리소스가 생겨
관리 주체가 둘로 나뉜다.

본 환경에서 `type: LoadBalancer` 를 쓰면 EXTERNAL-IP 가 `<pending>` 에 머물고
Gateway 가 `PROGRAMMED: False` 상태로 남는다.

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

HTTPRoute 는 애플리케이션 배포 시점에 정의한다.

**`PathPrefix` 매칭은 경로를 그대로 백엔드에 전달한다.**
`/api/users` 요청은 백엔드에 `/api/users` 로 도착한다.
백엔드가 접두사를 포함한 경로로 라우팅하거나, `URLRewrite` 필터로
접두사를 제거해야 한다. 백엔드 구현에 맞춰 결정한다.

## TLS 종단

| 구간 | 처리 |
| --- | --- |
| 클라이언트 → CloudFront | ACM (us-east-1) |
| CloudFront → Public NLB | ACM (ap-northeast-1), `origin.re-used.store` |
| NLB → Envoy | 평문. VPC 내부 구간 |

Envoy Gateway 는 TLS 를 종단하지 않는다. 클러스터 내부 구간이며
NLB 가 이미 복호화한 트래픽을 받는다.

webhook 통신용 인증서는 Helm 차트의 certgen Job 이 자체 생성한다.
**cert-manager 가 필요하지 않다.**

## 클라이언트 IP 식별

Public NLB 는 Client IP Preservation 을 비활성화했다
(`docs/05-loadbalancer.md` 참조).
활성 상태에서는 Worker Node 가 보는 출발지가 CloudFront IP 가 되어
`sg-public-nlb → sg-worker` SG 참조 규칙이 동작하지 않는다.

따라서 Envoy 가 보는 출발지 IP 는 NLB 주소이며,
실제 클라이언트 IP 는 CloudFront 가 전달하는 `X-Forwarded-For` 로 식별한다.

Envoy 는 기본적으로 XFF 헤더를 처리하고 접근 로그에 기록한다.
신뢰할 홉 수를 조정하려면 `ClientTrafficPolicy` 를 사용한다.
CloudFront 연결 후 실제 헤더 값을 보고 설정한다.

## 구축 결과

| 항목 | 상태 |
| --- | --- |
| 컨트롤플레인 | 2 Pod |
| 데이터플레인 | 3 Pod (Worker 3대에 분산) |
| GatewayClass | Accepted |
| Gateway | Programmed |
| NodePort | 30080 고정 |
| NLB 타겟 | Worker 3대 healthy |

Pod 배치 노드는 스케줄러가 결정하므로 재시작 시 달라질 수 있다.
`topologySpreadConstraints` 로 노드당 1개씩 분산되는 것만 보장한다.

라우트가 없는 상태에서 노드 3대 모두 404 를 응답한다.
Envoy 가 요청을 받았으나 매칭되는 HTTPRoute 가 없다는 뜻이며 정상이다.

## 미결정 사항

| 항목 | 결정 시점 |
| --- | --- |
| HTTPRoute 세부 정의 | 애플리케이션 배포 시 |
| `PathPrefix` 접두사 처리 방식 | 백엔드 구현 확정 후 |
| `ClientTrafficPolicy` XFF 설정 | CloudFront 연결 후 |
| Envoy Proxy 리소스 요청·제한 | 부하 테스트 후 |
| 다중 Gateway 여부 | 현재 단일 Gateway |
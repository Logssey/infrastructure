# Gateway API — Ingress 의 후속과 구현체 선택

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| Gateway API 공식 | https://gateway-api.sigs.k8s.io/ |
| 구현체 목록과 conformance | https://gateway-api.sigs.k8s.io/docs/implementations/list/ |
| Ingress NGINX 은퇴 공지 (SIG Network) | https://www.kubernetes.dev/blog/2025/11/12/ingress-nginx-retirement/ |
| Gateway API v1.6 릴리스 | https://kubernetes.io/blog/2026/08/03/gateway-api-v1-6-release/ |
| Gateway API v1.0 GA | https://kubernetes.io/blog/2023/10/31/gateway-api-ga/ |
| ingress2gateway | https://github.com/kubernetes-sigs/ingress2gateway |
| Envoy Gateway | https://gateway.envoyproxy.io/docs/ |
| Cilium Gateway API | https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/ |

---

## Ingress 가 남긴 문제

Ingress API 는 2020년 Kubernetes 1.19 에서 GA 되었다.
클러스터 외부에서 들어오는 HTTP 트래픽을 Service 로 보내는 표준이었다.

**제거되지 않았고 제거 계획도 없다.**

다만 feature-frozen 상태다.
새 기능이 추가되지 않으며, 활발한 개발은 Gateway API 로 옮겨갔다.

문제가 셋 있었다.

### 어노테이션 의존

Ingress 스펙이 정의하는 것은 호스트, 경로, 백엔드 Service 정도다.
그 외의 모든 것은 어노테이션으로 표현해야 했다.

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/proxy-body-size: 50m
    nginx.ingress.kubernetes.io/canary-weight: "10"
```

**어노테이션은 구현체마다 다르다.**

nginx 용으로 쓴 Ingress 를 Traefik 으로 옮기면 전부 다시 써야 한다.
이식성이 없다는 뜻이고, 사실상 벤더 종속이다.

타입 검증도 없다.
오타가 나도 API 서버가 받아들이고, 런타임에 무시될 뿐이다.

### 역할 분리가 없다

Ingress 리소스 하나에 모든 것이 들어 있다.

| 내용 | 원래 누가 정해야 하나 |
| --- | --- |
| TLS 인증서 | 플랫폼 팀 |
| 로드밸런서 설정 | 플랫폼 팀 |
| 라우팅 규칙 | 애플리케이션 팀 |

**하나의 리소스라 권한을 나눌 수 없다.**

애플리케이션 팀에게 Ingress 생성 권한을 주면 TLS 설정도 건드릴 수 있다.

### HTTP 만 다룬다

TCP, UDP, gRPC 는 스펙에 없다.

구현체가 각자 어노테이션이나 별도 CRD 로 해결했고, 역시 이식성이 없었다.

---

## Ingress NGINX 은퇴

2025년 11월, Kubernetes SIG Network 와 Security Response Committee 가
`kubernetes/ingress-nginx` 의 은퇴를 공동 발표했다.

**2026년 3월에 유지보수가 종료되었다.**

릴리스, 버그 수정, 보안 패치가 더 이상 없다.
저장소는 읽기 전용이 되었다.

### 왜 은퇴했는가

공식 발표가 밝힌 이유는 **기여자 부족**이다.

> 광범위한 사용에도 불구하고, 그리고 메인테이너들의 반복된 도움 요청에도 불구하고
> Ingress NGINX 프로젝트는 필요한 기여자를 얻지 못했다.
>
> Datadog 내부 조사에 따르면 클라우드 네이티브 환경의 약 50% 가 이 도구에 의존하는데,
> 지난 수년간 한두 명이 여유 시간에 유지해 왔다.

프로젝트 규모와 유지보수 인력의 불균형이 핵심이다.

### 무엇이 은퇴하지 않았는가

이름이 비슷한 것들이 많아 혼동하기 쉽다.

| 대상 | 상태 |
| --- | --- |
| `kubernetes/ingress-nginx` | **EOL.** 저장소 읽기 전용 |
| Kubernetes Ingress API | 유지. feature-frozen |
| `nginxinc/kubernetes-ingress` (F5) | 유지. 별개 코드베이스 |
| nginx 웹 서버 | 무관 |
| Traefik, HAProxy, Kong 등 | 무관 |

**Ingress 자체가 죽은 것이 아니다.**

가장 널리 쓰이던 구현체 하나가 없어진 것이다.

### 기존 배포는 어떻게 되는가

공식 공지는 명확하다.

> 기존 Ingress NGINX 배포는 계속 동작한다.
> 설치 아티팩트도 계속 사용할 수 있다.

당장 깨지는 것은 없다.
**새 CVE 가 나와도 고쳐지지 않을 뿐이다.**

다만 Kubernetes 프로젝트의 표현은 강경하다.

> 분명히 말하면, 은퇴 후에도 Ingress NGINX 를 계속 쓰는 것은
> 당신과 사용자를 공격에 노출시키는 선택이다.
>
> 그리고 직접적인 drop-in 대체재는 없다.

권장 경로는 Gateway API 로의 이동이다.
Ingress 를 계속 써야 한다면 유지되는 다른 컨트롤러를 쓰라는 것이 공식 입장이다.

사용 여부는 아래로 확인할 수 있다.

```bash
kubectl get pods --all-namespaces \
  --selector app.kubernetes.io/name=ingress-nginx
```

---

## Gateway API 란

SIG Network 가 설계한 CRD 집합이다.
Ingress 의 세 문제를 정면으로 다룬다.

| Ingress 의 문제 | Gateway API 의 해법 |
| --- | --- |
| 어노테이션 의존 | 기능을 스펙 필드로 표현 |
| 역할 분리 없음 | 리소스를 세 계층으로 분리 |
| HTTP 만 | HTTPRoute, GRPCRoute, TLSRoute, TCPRoute, UDPRoute |

### 리소스 모델

```
GatewayClass          클러스터 범위. 어떤 구현체가 처리하는가
    ↑ gatewayClassName
Gateway               네임스페이스. 리스너, 포트, 인증서
    ↑ parentRefs
HTTPRoute             네임스페이스. 경로, 헤더, 백엔드
```

**Ingress 에는 Gateway 에 해당하는 계층이 없었다.**

컨트롤러를 배포하는 것이 곧 리스너를 만드는 것이었다.
"어떤 포트로 무엇을 받을지" 를 선언적으로 표현할 방법이 없었다.

### 역할 분리

| 리소스 | 범위 | 소유 |
| --- | --- | --- |
| GatewayClass | 클러스터 | 인프라 제공자 / 클러스터 관리자 |
| Gateway | 네임스페이스 | 플랫폼 팀 |
| Route | 네임스페이스 | 애플리케이션 팀 |

RBAC 로 권한을 나눌 수 있다.

애플리케이션 팀에게 HTTPRoute 생성 권한만 주면
라우팅은 스스로 바꾸되 TLS 설정은 건드릴 수 없다.

### 양방향 승인

Gateway 와 Route 는 서로를 승인해야 연결된다.

```yaml
# Gateway 쪽: 누구의 Route 를 받을 것인가
listeners:
  - allowedRoutes:
      namespaces:
        from: All        # 또는 Same, Selector

# Route 쪽: 어느 Gateway 에 붙을 것인가
parentRefs:
  - name: eg
    namespace: envoy-gateway-system
```

**한쪽만으로는 연결되지 않는다.**

다른 네임스페이스의 Route 가 임의로 Gateway 를 점유하는 것을 막는다.

Ingress 에는 이 개념이 없었다.
같은 호스트를 여러 Ingress 가 선언하면 구현체마다 다르게 처리했다.

### 상태를 읽을 수 있다

Gateway API 리소스는 `status` 에 처리 결과를 기록한다.

```
Gateway.status.listeners[].conditions
  Accepted       설정이 유효한가
  ResolvedRefs   참조 대상(인증서, Route)을 찾았는가
  Programmed     데이터플레인에 실제로 반영되었는가

Gateway.status.listeners[].attachedRoutes
  이 리스너에 붙은 Route 수
```

**세 조건이 단계적이다.**

`Accepted` 는 True 인데 `Programmed` 가 False 라면
설정은 맞지만 프록시에 전달되지 않은 상태다.

Ingress 는 `status.loadBalancer.ingress` 에 주소만 기록했다.
왜 동작하지 않는지 알려면 컨트롤러 로그를 봐야 했다.

---

## 채널과 GA 범위

Gateway API 는 두 채널로 배포된다.

| 채널 | 의미 |
| --- | --- |
| **Standard** | GA. 하위 호환이 보장된다 |
| **Experimental** | 변경될 수 있다. 별도 CRD 번들 |

리소스가 단계적으로 Standard 로 승격되어 왔다.

| 릴리스 | Standard 로 승격 |
| --- | --- |
| v1.0 (2023-10) | GatewayClass, Gateway, HTTPRoute |
| v1.1 | GRPCRoute, Service Mesh (GAMMA) |
| v1.5 | TLSRoute, ListenerSet |
| **v1.6 (2026-06-30)** | **TCPRoute, UDPRoute** |

**v1.6 으로 L4 라우팅까지 Standard 가 되었다.**

이전에는 데이터베이스, DNS, VoIP 같은 원시 TCP/UDP 워크로드를
Gateway 에 붙일 이식 가능한 방법이 없었다.

Service 로 돌아가거나 구현체별 CRD 를 써야 했고, 둘 다 이식성이 없었다.

TCPRoute 와 UDPRoute 의 `v1alpha2` 버전은 v1.6 에서 deprecated 되었다.
향후 릴리스에서 제거되므로 실험 채널로 쓰고 있었다면 마이그레이션이 필요하다.

### 실험 리소스가 별도 API 그룹으로 분리되었다

v1.6 부터 새 실험 리소스는 `gateway.networking.x-k8s.io` 그룹에 정의된다.
타입 이름에는 `X` 접두사가 붙는다. `XBackend`, `XMesh` 같은 식이다.

Standard 로 승격되면 `gateway.networking.k8s.io` 그룹으로 옮겨가며 접두사를 뗀다.

**실험과 표준의 경계가 API 그룹 수준에서 명확해졌다.**

버전 문자열로 구분하던 방식보다 안전하다.

---

## conformance 를 읽는 법

구현체들이 모두 "Gateway API conformant" 를 표방한다.
그러나 그 의미가 같지 않다.

### 기능 등급이 셋이다

| 등급 | 의미 |
| --- | --- |
| **Core** | 모든 구현체가 지원해야 하는 최소 |
| **Extended** | 권장되지만 선택 |
| **Implementation-specific** | 벤더 확장 영역 |

### 공식 분류는 둘이다

| 등급 | 조건 |
| --- | --- |
| **Conformant** | 최근 2개 릴리스 중 하나에 대해, 최소 하나의 Profile + Route type 조합에서 모든 Core 테스트를 통과하고, 주장한 모든 Extended 기능도 통과한 리포트를 제출 |
| **Partially Conformant** | 완전 준수를 목표로 하나 아직 미달. 최근 3개 릴리스 중 하나에 대해 일부 테스트를 통과한 리포트를 제출 |

**Core 만 통과하면 되는 것이 아니다.**

구현체가 "우리는 이 Extended 기능을 지원한다" 고 주장했다면
그 기능들의 테스트도 모두 통과해야 Conformant 다.

다만 어떤 Extended 기능을 주장할지는 구현체가 정한다.
그래서 두 구현체가 모두 Conformant 라도 지원 범위는 다를 수 있다.

### 프로필이 둘이다

| 프로필 | 다루는 트래픽 |
| --- | --- |
| **Gateway** | 남북. 클러스터 외부에서 내부로 |
| **Mesh** | 동서. 클러스터 내부 서비스 간 |

구현체가 둘 다 지원할 수도 있다.

### 조회 시점(2026-09) 분류

Gateway controller 프로필 기준이다.

| 등급 | 구현체 |
| --- | --- |
| **Conformant** | Agentgateway, Airlock Microgateway, Cilium, Envoy Gateway, GKE, Gravitee, Higress, Istio, Kgateway, Kong Operator, Lexfrei's Cloudflare Tunnel, N42 Gateway, NGINX Gateway Fabric, Traefik Proxy, Varnish Gateway, WSO2 Gateway |
| **Partially Conformant** | AWS Load Balancer Controller, Amazon EKS, Calico, Gloo Gateway |

Mesh 프로필에서 Conformant 인 것은 **Cilium 과 Istio** 둘이다.

Partially Conformant 가 품질이 낮다는 뜻은 아니다.
리포트 제출 시점이나 대상 릴리스 차이인 경우가 많다.

### 실무에서 필요한 기능은 대개 확장 영역에 있다

인증, 레이트 리밋, 서킷 브레이킹 같은 것들이
Extended 또는 Implementation-specific 에 속한다.

| 기능 | Envoy Gateway | Istio |
| --- | --- | --- |
| 인증·인가 | `SecurityPolicy` | `AuthorizationPolicy` |
| 트래픽 제어 | `BackendTrafficPolicy` | `DestinationRule` |

**이런 CRD 를 쓰는 순간 그 구현체에 종속된다.**

Gateway API 표준 부분은 이식 가능하지만, 확장 부분은 그렇지 않다.

"표준이니까 나중에 갈아타면 된다" 는 기대는 절반만 맞다.

---

## 구현체 비교

선택지가 많다는 것 자체가 Gateway API 전환의 난점이다.
ingress-nginx 시절에는 사실상 기본값이 있었으나 지금은 없다.

### 데이터플레인 기준

| 데이터플레인 | 구현체 |
| --- | --- |
| Envoy | Envoy Gateway, Istio, Kgateway, Higress, Calico, Cilium(L7) |
| nginx | NGINX Gateway Fabric |
| eBPF (L4) | Cilium |
| Rust | Agentgateway |
| 자체 | Traefik, Kong, Varnish, N42(HAProxy) |

**Envoy 기반이 다수다.**

Envoy 가 xDS 라는 동적 설정 API 를 제공해 컨트롤플레인을 붙이기 쉬운 구조이기 때문이다.

Calico 의 Gateway API 구현이 Envoy Gateway 위에 만들어진 것도 같은 맥락이다.
`tigera-operator` 가 Envoy Gateway 컨트롤플레인을 프로비저닝하는 구조다.

### 주요 구현체

**Envoy Gateway**

Envoy 프로젝트의 서브프로젝트다.
Envoy 기반 애플리케이션 게이트웨이를 관리하는 것이 목적이다.

**Istio**

서비스 메시이자 게이트웨이 구현체다.
최소 설치로 Gateway API 만 쓸 수도 있고,
GAMMA 를 통해 메시 내부 동서 트래픽까지 다룰 수도 있다.

Gateway 와 Mesh 프로필 모두 Conformant 다.

**NGINX Gateway Fabric**

NGINX 를 데이터플레인으로 쓰는 공식 구현체다.
ingress-nginx 에서 넘어오는 팀에게 익숙한 경로다.

**Cilium**

eBPF 기반 네트워킹·관측성·보안 솔루션이 Gateway API 까지 제공한다.
사이드카 없는 메시 데이터플레인을 갖고 있다.

Gateway 와 Mesh 프로필 모두 Conformant 다.

**Kgateway**

Envoy 기반이며 AI·MCP 게이트웨이 시나리오에 초점을 둔다.

**Kong**

API 게이트웨이 기능(플러그인, 인증)이 강점이다.

**Agentgateway**

Linux Foundation 산하이며 LLM, A2A, MCP 같은 AI 유스케이스를 겨냥한다.
Rust 데이터플레인을 쓴다.

### Envoy 기반이 많은 이유

Envoy 자체가 **대규모 운영으로 검증된 프록시**이기 때문이다.
Databricks, Google, Lyft, Netflix, Spotify 등이 운영 환경에서 사용한다.

그 위에 생태계가 쌓이고 있다.

2026년 6월 CNCF Envoy Gateway 를 기반으로 한 Envoy AI Gateway 가 v1.0 에 도달했다.
Bloomberg, Nutanix, Netflix, AMD 소속 메인테이너가 참여했고,
AWS 는 이를 Amazon EKS 의 선호 AI 게이트웨이로 채택했다.

**구현체를 고를 때 데이터플레인의 생태계 규모가 중요한 이유가 여기 있다.**

확장 기능은 결국 데이터플레인이 무엇을 할 수 있느냐에 달려 있다.
커뮤니티가 크면 필요한 기능이 이미 있거나 곧 생긴다.

---

## CNI 가 Gateway API 를 지원하면 그것을 쓰면 되지 않나

Cilium 을 CNI 로 쓰는 경우 자연스럽게 떠오르는 선택지다.
컴포넌트가 하나 줄고, eBPF 데이터패스와 통합된다.

**필수는 아니다.**
그리고 기능이나 성숙도가 부족해서 피할 이유도 없다.

Cilium 은 Gateway 와 Mesh 프로필 모두 Conformant 이고,
Mesh 프로필까지 통과한 것은 Istio 와 Cilium 둘뿐이다.

판단은 다른 축에서 이뤄진다.

### 수명주기 분리

흔히 "장애 격리" 로 설명되지만 **정확한 표현이 아니다.**

Cilium 이 CNI 인 이상 Cilium 이 죽으면 Pod 네트워킹 자체가 멈춘다.
게이트웨이를 분리해도 그 장애는 그대로 전파된다.

실제로 분리되는 것은 **변경과 업그레이드의 단위**다.

| 상황 | 분리 효과 |
| --- | --- |
| Cilium 장애 | 없음. 게이트웨이도 함께 영향받는다 |
| Cilium 업그레이드 | 있음. 게이트웨이 설정과 무관하게 진행 |
| 게이트웨이 버전 선택 | 있음. CNI 릴리스 주기에 묶이지 않는다 |
| CNI 교체 | 있음. 게이트웨이를 그대로 둘 수 있다 |

CNI 는 클러스터 전체에 영향을 주므로 업그레이드가 신중해진다.
게이트웨이는 트래픽 정책이 바뀔 때마다 손댄다.

**변경 빈도가 다른 둘을 한 컴포넌트로 묶으면 서로를 제약한다.**

반대로 분리하면 컴포넌트가 늘고 리소스도 더 쓴다.
트레이드오프다.

### 확장 생태계의 방향이 다르다

| | Envoy Gateway | Cilium Gateway API |
| --- | --- | --- |
| 확장 방향 | Envoy 기능 노출 | eBPF·네트워크 정책과의 통합 |
| 유리한 경우 | L7 트래픽 제어를 깊이 쓸 때 | 네트워크 정책과 게이트웨이를 하나로 다룰 때 |

### 규모가 작으면 통합이 합리적일 수 있다

컴포넌트 하나에 Pod 다섯 개, 메모리 수백 Mi 가 따라온다.
노드가 적거나 리소스가 빠듯하면 그 자체로 의미 있는 비용이다.

**"분리가 항상 옳다" 는 판단은 근거가 약하다.**

분리로 얻는 것이 그 비용을 넘어서는지 따져야 한다.

---

## 선택 기준

```
1. 이미 Istio 서비스 메시를 쓰거나 도입할 계획인가?
   예    → Istio Gateway
   아니오 → 다음

2. ingress-nginx 에서 마이그레이션하는가?
   예    → NGINX Gateway Fabric 또는 어노테이션 호환을 제공하는 컨트롤러
   아니오 → 다음

3. API 게이트웨이 기능(플러그인, 인증)이 핵심인가?
   예    → Kong
   아니오 → 다음

4. CNI 가 Cilium 이고 컴포넌트 수를 줄이는 것이 우선인가?
   예    → Cilium Gateway API
   아니오 → Envoy Gateway
```

**정답이 하나로 수렴하지 않는다.**

ingress-nginx 라는 기본값이 사라진 상태에서
모든 팀이 동시에 선택을 요구받고 있다.

첫 선택의 무게가 크다.
표준 부분은 이식 가능하지만 실제로 쓰게 되는 확장 CRD 는 그렇지 않기 때문이다.

### 마이그레이션 도구

기존 Ingress 가 있다면 `ingress2gateway` 로 변환할 수 있다.

다만 **변환할 수 없는 어노테이션이 존재한다.**
Gateway API 에 대응하는 개념이 없는 것들이다.

도구의 출력은 사람이 검토해야 하고, 구현체별 테스트가 필요하다.
공식 공지도 "직접적인 drop-in 대체재는 없다" 고 명시했다.

---

## 우리의 선택 — Envoy Gateway

### Gateway API 를 고른 이유

| 기준 | 판단 |
| --- | --- |
| 신규 프로젝트 | 마이그레이션 부담이 없다 |
| 생태계 방향 | 활발한 개발이 Gateway API 로 옮겨갔다. Ingress API 는 feature-frozen |
| 서비스 요구사항 | HTTP 와 WebSocket 을 함께 다뤄야 한다 |

**기존 자산이 없다는 점이 가장 컸다.**

운영 중인 Ingress 가 있었다면 마이그레이션 비용과 이점을 저울질해야 했다.
새로 만드는 클러스터에서는 그 계산이 필요 없다.

Ingress 가 나쁘다는 판단은 아니다.
Ingress API 는 여전히 유효하고 유지되는 구현체도 많다.

단순한 HTTP 라우팅만 필요하다면 지금도 합리적인 선택이다.

### 배제한 후보

| 후보 | 이유 |
| --- | --- |
| Istio | 메시가 필요 없는데 메시 컨트롤플레인이 따라온다 |
| NGINX Gateway Fabric | 주된 강점인 마이그레이션 지원이 적용되지 않는다 |
| Kong | API 게이트웨이 기능이 핵심 요구가 아니다 |

### 남은 둘 사이의 선택

**Cilium Gateway API 와 Envoy Gateway 사이에는 기술적 우열이 없었다.**

HTTP 라우팅, WebSocket, 트래픽 분할 모두 양쪽에서 가능하고
conformance 등급도 같다.
현재 요구사항 중 어느 한쪽이어야만 하는 것은 없다.

판단 기준은 **운영 단위를 어떻게 나눌 것인가** 하나였다.

| 계층 | 변경 성격 |
| --- | --- |
| CNI | 클러스터 전체에 영향. 업그레이드가 신중하고 드물다 |
| 게이트웨이 | 트래픽 정책. 상대적으로 자주 바뀐다 |

CNI 를 올리려면 게이트웨이 설정 호환성을 함께 봐야 한다.
게이트웨이 기능을 쓰려면 CNI 버전이 전제가 된다.

**변경 빈도가 다른 둘을 묶으면 서로를 제약한다.**

CNI 를 교체하더라도 게이트웨이를 그대로 둘 수 있다는 점도 같은 맥락이다.
Cilium Gateway API 를 쓰면 CNI 교체가 곧 게이트웨이 교체가 된다.

부수적으로, Envoy 설정 구조는 다른 구현체로도 이어진다.
Istio, Kgateway, Higress, Calico 등이 Envoy 기반이므로
리스너·라우트·클러스터·xDS 를 이해하면 구현체를 바꿔도 상당 부분 재사용된다.

결정적인 근거는 아니지만 선택을 되돌릴 때의 비용을 낮춘다.

### 치른 비용

Cilium 을 썼다면 없었을 Pod 가 추가되었다.

| 컴포넌트 | 배포 | Pod 당 메모리 |
| --- | --- | --- |
| envoy-gateway (컨트롤플레인) | Deployment ×2 | 약 120Mi |
| Envoy Proxy | Deployment ×3 | 약 130~165Mi |

합계 약 640Mi 다.

Worker 3대의 Allocatable 이 노드당 6.8Gi 이므로 현재 규모에서는 감당 가능하다.
다만 공짜가 아니라는 점은 분명하다.

**컴포넌트 수를 줄이는 것이 우선이었다면 Cilium 이 맞았을 것이다.**
어느 쪽을 고르든 틀린 선택은 아니며, 무엇을 우선하느냐의 문제다.

### 우리 구성

| 항목 | 값 |
| --- | --- |
| 버전 | Envoy Gateway v1.9.1, Gateway API v1.6.1 |
| GatewayClass | `eg` |
| Gateway | `eg` (envoy-gateway-system), HTTP 80 리스너 |
| allowedRoutes | `All`. 모든 네임스페이스의 Route 허용 |
| 노출 방식 | NodePort 30080 고정 → Public NLB 타겟 |
| TLS | NLB 에서 종단. Gateway 는 평문으로 받는다 |

**TLS 를 Gateway 가 아니라 NLB 에서 종단한다.**

CloudFront → NLB 구간이 이미 HTTPS 이고, NLB → Envoy 는 VPC 내부이기 때문이다.
Gateway 에 인증서를 두면 관리 지점이 하나 더 늘어난다.

**`allowedRoutes: All` 은 현재 단계의 설정이다.**

네임스페이스가 늘어나면 `Selector` 로 좁히는 것이 맞다.
지금은 애플리케이션이 없어 제한할 대상 자체가 없다.

> NodePort 고정 과정에서 겪은 문제는
> [troubleshooting/08](../troubleshooting/08-envoy-gateway-nodeport.md) 참조.

구체적인 설정값과 진입 경로는 [docs/07-ingress.md](../07-ingress.md) 참조.
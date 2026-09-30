# eBPF — 커널 데이터패스와 kube-proxy 대체

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| eBPF 공식 | https://ebpf.io/what-is-ebpf/ |
| Kubernetes 가상 IP 와 Service 프록시 | https://kubernetes.io/docs/reference/networking/virtual-ips/ |
| KEP-3866 nftables proxy | https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/3866-nftables-proxy |
| KEP-5495 IPVS deprecation | https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/5495-deprecate-ipvs-mode-in-kube-proxy |
| Cilium kube-proxy replacement | https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/ |
| Cilium eBPF datapath | https://docs.cilium.io/en/stable/network/ebpf/ |
| Cilium 성능 벤치마크 | https://docs.cilium.io/en/stable/operations/performance/benchmark/ |

---

## eBPF 란 무엇인가

**커널 안에서 사용자가 작성한 프로그램을 실행하는 기술이다.**

전통적으로 커널 동작을 바꾸려면 두 가지 방법뿐이었다.

| 방법 | 문제 |
| --- | --- |
| 커널 소스 수정 후 재빌드 | 배포와 유지보수가 비현실적 |
| 커널 모듈 작성 | 버그 하나로 시스템 전체가 죽는다 |

eBPF 는 세 번째 길을 만들었다.
프로그램을 커널에 올리되, **올리기 전에 검증기(verifier)가 안전성을 확인**한다.

```
사용자 공간에서 프로그램 작성 (C 등)
        ↓ 컴파일
eBPF 바이트코드
        ↓ 커널에 로드
검증기: 무한 루프 없나, 메모리 접근이 안전한가
        ↓ 통과
JIT 컴파일 → 네이티브 코드로 실행
```

검증을 통과하지 못하면 로드 자체가 거부된다.
그래서 **커널 모듈과 달리 시스템을 죽일 수 없다.**

### 어디에 붙는가

eBPF 프로그램은 커널의 특정 지점(hook)에 연결된다.

| Hook | 위치 | 용도 |
| --- | --- | --- |
| XDP | NIC 드라이버 직후 | 가장 빠름. DDoS 차단, 로드밸런싱 |
| TC | 트래픽 제어 계층 | 패킷 조작, 정책 적용 |
| socket | 소켓 연산 | 연결 단위 처리 |
| kprobe / tracepoint | 커널 함수 | 관측, 프로파일링 |

네트워킹만의 기술이 아니다.
관측성(Pixie, OBI), 보안(Falco, Tetragon), 프로파일링(Parca)에도 쓰인다.

### 맵 — 상태를 저장하는 곳

eBPF 프로그램은 실행될 때마다 처음부터 시작한다. 상태를 기억하려면 **맵**이 필요하다.

맵은 커널 공간의 키·값 저장소이며, 사용자 공간에서도 읽고 쓸 수 있다.

```
사용자 공간 에이전트          커널
  (Cilium agent)     ←→   eBPF 맵   ←→   eBPF 프로그램
     맵을 갱신                           맵을 조회해 판단
```

**이 구조가 성능의 핵심이다.**
정책이 바뀌면 에이전트가 맵만 갱신한다. 프로그램을 다시 로드할 필요가 없고,
패킷 처리 경로는 맵을 한 번 조회할 뿐이다.

---

## Service 는 어떻게 구현되는가

Kubernetes Service 의 ClusterIP 는 **실재하지 않는 주소**다.  
어떤 네트워크 인터페이스도 그 IP 를 갖고 있지 않고, 아무도 그 주소로 응답하지 않는다.

```
Service nginx-test
  ClusterIP: 10.96.145.84:80
  Endpoints: 10.244.1.122:80, 10.244.2.136:80
```

`10.96.145.84` 로 보낸 패킷이 실제 Pod 에 도달하려면
**누군가 목적지 주소를 바꿔야 한다(DNAT).**

그 일을 하는 것이 kube-proxy 다.
kube-proxy 는 Service 와 EndpointSlice 를 watch 하다가 커널에 규칙을 넣는다.

**kube-proxy 자체는 패킷을 처리하지 않는다.**
규칙을 설정할 뿐, 실제 변환은 커널이 한다. 이름이 오해를 부르는 부분이다.

---

## 네 가지 구현 방식

같은 일을 하는 방식이 넷이다. 앞의 셋은 kube-proxy 의 모드이고,
넷째는 kube-proxy 를 아예 쓰지 않는 방식이다.

### iptables

Kubernetes 의 오랜 기본값이며, 조회 시점(2026-09) 기준으로도 여전히 upstream 기본값이다.

Service 마다 체인을 만들고, 그 안에 백엔드별 규칙을 넣는다.
`statistic` 모듈로 확률 기반 분배를 구현한다.

```
PREROUTING → KUBE-SERVICES → KUBE-SVC-XXX → KUBE-SEP-YYY → DNAT
```

**규칙이 선형으로 평가된다.** 목록의 위에서부터 하나씩 비교하므로
Service 가 늘면 평균 탐색 시간도 늘어난다.

더 큰 문제는 갱신 비용이다.
규칙 하나를 바꾸려면 **전체 테이블을 다시 쓴다.**  
Service 와 엔드포인트가 수만 개 수준인 클러스터에서는 규칙 갱신과 순회에 상당한 시간이 소요된다.

### IPVS

커널의 L4 로드밸런서를 사용한다. 해시 테이블 기반이라 조회가 상수 시간이다.

규칙 갱신도 증분으로 이뤄져 iptables 보다 빠르다.
로드밸런싱 알고리즘도 여러 가지를 고를 수 있다(rr, lc, sh 등).

**Kubernetes 1.35 에서 deprecated 되었다.**

KEP-5495 가 제시한 단계는 아래와 같다.
아직 진행 중인 계획이므로 실제 일정은 달라질 수 있다.

| 버전 | 계획 |
| --- | --- |
| 1.35 | deprecated 선언 |
| 1.37 | `KubeProxyIPVS` feature gate 추가 (기본 활성) |
| 1.40 (예정) | feature gate 기본 비활성 |
| 1.43 (예정) | 코드 제거 |

deprecated 된 이유는 두 가지다.

첫째, **IPVS 만으로 Service 를 완전히 구현할 수 없다.**
IPVS 모드도 내부적으로 iptables API 를 상당히 사용한다.
iptables 에서 벗어나려는 목적과 맞지 않는다.

둘째, **로드밸런싱 알고리즘 선택이 실제로는 쓸모가 적다.**
Kubernetes 환경에서 라운드로빈 외의 스케줄러가 의미 있게 동작하는 경우가 드물다는 것이
업스트림의 설명이다.

### nftables

iptables 의 후속 기술이다. **Kubernetes 1.33 에서 GA** 되었다.

단일 테이블에 verdict map 을 두고 `목적지IP:포트` 로 한 번에 분기한다.
선형 탐색이 아니라 맵 조회다.

| 항목 | 내용 |
| --- | --- |
| 커널 요구 | 5.13 이상 |
| 성능 | iptables·IPVS 보다 우수 |
| 갱신 | 증분 갱신 지원 |
| 현재 기본값 | 아님. upstream 기본은 여전히 iptables |

RHEL 이 iptables 를 deprecated 한 것도 배경이다.
RHEL 10 에서는 iptables API 를 쓸 수 없어 nftables 로 가야 한다.

kube-proxy 의 기본 모드가 nftables 로 바뀌는 방향으로 논의가 진행 중이다.

### eBPF — kube-proxy 를 대체

앞의 셋과 성격이 다르다. **kube-proxy 를 실행하지 않는다.**

CNI 에이전트(Cilium 등)가 직접 eBPF 맵을 관리하고,
커널의 eBPF 프로그램이 Service 변환을 처리한다.

```
Cilium agent (Service·EndpointSlice watch)
        ↓ 맵 갱신
eBPF Service 맵
        ↑ 조회
eBPF 프로그램 (TC / socket hook)
```

맵 조회는 해시 기반이라 **Service 수와 무관하게 상수 시간**이다.

#### socket 레벨 로드밸런싱

**동서 방향(Pod → Service) 트래픽에서 eBPF 만의 특징이다.**

Pod 안에서 `connect()` 를 호출하는 **그 순간** 목적지 주소를 Pod IP 로 바꾼다.
패킷이 만들어지기 전에 이미 실제 주소가 정해지는 것이다.

| 방식 | 변환 시점 |
| --- | --- |
| iptables / IPVS / nftables | 패킷이 네트워크 스택을 지날 때 |
| **eBPF socket LB** | **연결을 만들 때** |

결과적으로 **패킷마다 발생하던 NAT 비용이 사라진다.**
연결 한 번에 한 번만 변환하면 되기 때문이다.

#### 남북 방향 최적화

외부에서 들어오는 트래픽에는 다른 기법이 적용된다.

| 기법 | 내용 |
| --- | --- |
| XDP | NIC 드라이버 단계에서 처리. 커널 스택을 거의 거치지 않음 |
| DSR (Direct Server Return) | 응답을 로드밸런서를 거치지 않고 클라이언트에 직접 |
| Maglev | 일관성 해시. 백엔드가 바뀌어도 기존 연결이 유지됨 |

**이 세 가지는 kube-proxy 의 어느 모드에도 없다.**
대규모 남북 트래픽을 다루는 환경에서 eBPF 를 고르는 실질적 이유다.

---

## 비교

| | iptables | IPVS | nftables | eBPF |
| --- | --- | --- | --- | --- |
| 조회 | 선형 | 해시 | 맵 | 해시 |
| 갱신 | 전체 재작성 | 증분 | 증분 | 맵만 갱신 |
| 커널 요구 | 낮음 | 보통 | 5.13+ | 기능별로 다름 |
| kube-proxy | 필요 | 필요 | 필요 | **불필요** |
| socket LB | 없음 | 없음 | 없음 | **있음** |
| XDP / DSR / Maglev | 없음 | 없음 | 없음 | **있음** |
| 상태 | 기본값 | **deprecated** | GA | CNI 구현체에 종속 |
| 디버깅 | `iptables -L` | `ipvsadm -Ln` | `nft list ruleset` | 전용 도구 |

### 성능은 실제로 얼마나 차이 나는가

**소규모에서는 차이가 드러나지 않는다.**
Service 수십 개 수준에서는 네 방식 모두 체감되지 않고,
일부 벤치마크에서는 단순한 환경일수록 kube-proxy 쪽이 근소하게 앞서기도 한다.  

**규모가 커질수록 격차가 벌어진다.** 공개된 측정 결과의 경향은 아래와 같다.

| 상황 | 경향 |
| --- | --- |
| Service 1,000개 이상 | iptables 대비 P99 지연이 크게 낮고 CPU 사용도 절반 수준 |
| 100Gbps 처리 | eBPF 기반이 nftables 기반보다 CPU 를 덜 쓴다 |
| 정책 수백 개 | iptables 는 선형 평가 비용 증가, eBPF 는 영향 없음 |

Cilium 공식 벤치마크는 **최신 커널에서 eBPF 가 노드 간 baseline 에 근접하거나
때로는 상회한다**고 보고한다.   
컨테이너 네임스페이스 전달과 정책 적용이라는 추가 작업을 하면서도 그런 결과가 나오는 이유는 iptables 계층을 통째로 우회하기 때문이다.

**다만 수치는 커널 버전, 워크로드 성격, 측정 방법에 따라 크게 달라진다.**  
벤치마크를 절대값으로 받아들이기보다 **경향**으로 읽는 것이 맞다.
공통된 경향은 "eBPF 가 처음부터 조금 빠르고, 규모가 커질수록 덜 나빠진다" 는 것이다.

---

## kube-proxy replacement 가 하는 일

Cilium 의 `kubeProxyReplacement` 를 켜면 kube-proxy 를 제거할 수 있다.
eBPF 가 대신 처리하는 범위는 다음과 같다.

| 기능 | 내용 |
| --- | --- |
| ClusterIP | Service IP → Pod IP 변환 |
| NodePort | 노드 IP:포트 → Pod IP |
| LoadBalancer | 외부 LB 로부터의 트래픽 |
| ExternalIPs | |
| HostPort | CNI 플러그인 대신 처리 |
| 세션 어피니티 | conntrack 대신 eBPF 맵으로 구현 |

확인은 전용 명령으로 한다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

```
ID   Frontend                Service Type   Backend
6    0.0.0.0:30080/TCP       NodePort       1 => 10.244.0.39:10080
                                            2 => 10.244.1.202:10080
                                            3 => 10.244.2.106:10080
10   10.96.145.84:80/TCP     ClusterIP      1 => 10.244.1.122:80
                                            2 => 10.244.2.136:80
17   10.96.0.1:443/TCP       ClusterIP      1 => 10.20.10.10:6443
                                            2 => 10.20.11.10:6443
```

`iptables -t nat -L` 로는 이 정보가 보이지 않는다. **이것이 디버깅 방식의 근본적 차이다.**

### 병행은 불가능하다

kube-proxy 와 eBPF 가 같은 Service 를 처리하면 충돌한다.

두 주체가 각자 규칙을 넣고, 어느 쪽이 먼저 패킷을 잡느냐에 따라 결과가 달라진다.
증상이 간헐적으로 나타나 원인 추적이 어렵다.

> 우리 환경에서 kube-proxy IPVS 와 eBPF 가 병행되어 Service 접속이 실패한 사례가 있다.
> [troubleshooting/04](../troubleshooting/04-kube-proxy-ipvs-conflict.md) 참조.

---

## identity 기반 정책

eBPF 는 Service 변환뿐 아니라 NetworkPolicy 도 처리한다.
여기서 **IP 가 아닌 identity 를 기준으로 삼는** 것이 특징이다.

전통적 방화벽은 IP 로 규칙을 만든다. Pod IP 는 재시작할 때마다 바뀌므로
규칙을 계속 고쳐야 한다.

Cilium 은 Pod 의 라벨 조합을 하나의 숫자로 압축한다.

```
k8s:app=nginx-test
k8s:io.kubernetes.pod.namespace=default
k8s:io.cilium.k8s.policy.serviceaccount=default
        ↓
identity 1630
```

정책은 identity 로 표현되고, eBPF 는 숫자 비교만 한다.

**IP 가 바뀌어도 identity 는 그대로다.**
Pod 가 다른 노드로 옮겨가도, 재시작으로 IP 가 달라져도 정책이 유지된다.

| 개념 | 범위 |
| --- | --- |
| Endpoint ID | 노드 로컬. 같은 Pod 도 노드마다 다른 번호 |
| **Identity** | **클러스터 전역. 라벨이 같으면 같은 번호** |
| IP | 재시작하면 바뀜 |

ServiceAccount 가 identity 에 포함되는 점도 중요하다.
라벨은 누구나 붙일 수 있지만 ServiceAccount 는 RBAC 로 통제되므로,
"특정 ServiceAccount 를 쓰는 Pod 만 허용" 같은 정책이 더 강한 보증을 갖는다.

### L7 은 eBPF 만으로 처리하지 않는다

eBPF 는 L3/L4 에 적합하다. HTTP 헤더를 파싱하고 경로를 판단하는 일은
커널 안에서 하기 어렵다.

그래서 L7 정책이 있으면 **사용자 공간 프록시로 트래픽을 우회**시킨다.
Cilium 은 이 용도로 `cilium-envoy` 를 각 노드에 배치한다.

```
L3/L4 정책  →  eBPF 가 직접 처리
L7 정책     →  cilium-envoy 로 리다이렉트
```

L7 정책이 없으면 `cilium-envoy` 는 아무 일도 하지 않는다.

**노드당 하나라는 점이 사이드카 방식과의 차이다.**  
서비스 메시가 Pod 마다 프록시를 주입하는 것과 달리,
Cilium 은 노드에 하나만 두고 그 노드의 모든 Pod 를 처리한다.
Pod 수가 많을수록 메모리 차이가 커진다.

Cilium 1.19 는 이 구조 위에서 **사이드카 없는 mTLS** 를 제공한다.

**Ingress 용 Envoy Gateway 와는 전혀 다른 컴포넌트다.**
같은 Envoy 소프트웨어를 쓰지만 목적과 배치가 다르다. 이름 때문에 혼동하기 쉽다.

| | cilium-envoy | Envoy Gateway |
| --- | --- | --- |
| 네임스페이스 | kube-system | envoy-gateway-system |
| 배포 | DaemonSet | Deployment |
| 목적 | L7 NetworkPolicy | 외부 트래픽 라우팅 |

---

## 감수하는 것

### 디버깅 도구가 다르다

**가장 실질적인 비용이다.**

`iptables -L` 로 확인할 수 없다.
`cilium-dbg` 계열 명령을 익혀야 하고, eBPF 맵의 구조를 알아야 한다.
문제가 생겼을 때 검색으로 찾을 수 있는 자료도 아직은 iptables 만큼 많지 않다.

### iptables 를 직접 건드리면 안 된다

Cilium 이 관리하는 규칙을 수동으로 지우거나 수정하면 내부 상태가 깨진다.
증상이 엉뚱한 곳에서 나타나 원인 파악이 어렵다.

> 우리 환경에서 iptables 직접 조작으로 L7 정책이 동작하지 않게 된 사례가 있다.
> [troubleshooting/07](../troubleshooting/07-iptables-corruption-l7.md) 참조.

### 커널 요구사항을 기능별로 확인해야 한다

"Cilium 이 설치된다" 와 "이 기능을 쓸 수 있다" 는 다르다.
kube-proxy replacement, 호스트 라우팅, 대역폭 관리, XDP 가속 등이
각각 다른 커널 버전과 드라이버 지원을 요구한다.

### 네트워크 동작 방식이 바뀐다

eBPF 가 Service IP 를 직접 변환하므로, 기존에 로드밸런서를 거치던 트래픽이
목적지로 바로 간다. **방화벽 규칙의 전제가 달라진다.**

> Internal NLB 를 거칠 것으로 예상하고 SG 를 구성했으나
> eBPF 가 Control Plane 노드로 직접 보내 접속이 실패한 사례가 있다.
> [troubleshooting/05](../troubleshooting/05-apiserver-sg-kpr.md) 참조.

---

## 선택 기준

```
1. 커널이 5.13 이상인가?
   아니오 → iptables (선택의 여지가 없다)
   예    → 다음

2. Service 수가 수백 개를 넘거나 정책이 많은가?
   아니오 → iptables 로 충분. 운영이 가장 단순하다
   예    → nftables 또는 eBPF

3. CNI 가 eBPF 데이터플레인을 지원하는가?
   아니오 → nftables
   예    → 다음

4. L7 정책, 관측성, identity 기반 제어, 남북 트래픽 최적화가 필요한가?
   아니오 → nftables 로 충분. 디버깅이 훨씬 쉽다
   예    → eBPF
```

### 성능만 놓고 보면

**eBPF 가 가장 빠르다.** 특히 규모가 커질수록 격차가 벌어진다.

다만 성능 하나만으로 결정하기는 어렵다.

| 관점 | 내용 |
| --- | --- |
| 대부분의 클러스터 규모 | 네 방식 모두 체감 차이가 없다 |
| nftables 로 해결되는 범위 | iptables 의 성능 문제 대부분 |
| eBPF 가 추가로 주는 것 | socket LB, XDP·DSR·Maglev, L7, 관측성 |
| 치르는 비용 | 디버깅 난이도, 커널 요구사항 |

**성능이 유일한 기준이라면 eBPF 가 맞다.**
운영 단순성이 더 중요하다면 nftables 도 합리적인 선택이다.

### IPVS 는 선택지에서 제외한다

새로 구축하는 클러스터라면 고려할 이유가 없다.
제거가 예정되어 있고, nftables 가 대부분의 면에서 낫다.

기존에 IPVS 를 쓰고 있다면 기본 비활성 예정 시점 이전에
마이그레이션을 계획하는 것이 안전하다.

---

## 생태계 동향

주요 관리형 Kubernetes 가 eBPF 데이터플레인을 선택지로 제공한다.
GKE Dataplane V2, Azure CNI Powered by Cilium, EKS Anywhere 가 그렇다.

kube-proxy 자체도 iptables 에서 벗어나는 중이다.
nftables 모드가 GA 되었고 IPVS 는 제거 절차에 들어갔다.

**두 흐름은 별개다.** kube-proxy 를 개선하는 방향(nftables)과
kube-proxy 를 없애는 방향(eBPF)이 동시에 진행되고 있다.

---

## 우리의 선택 — kube-proxy replacement

Cilium 을 CNI 로 골랐으므로([cni.md](cni.md) 참조) eBPF 는 자연스러운 귀결이었다.
남은 판단은 kube-proxy 를 함께 둘 것인가였다.

| 기준 | 판단 |
| --- | --- |
| 커널 | Ubuntu 24.04, 커널 7.0. 요구사항 충족 |
| Service 수 | 현재 10개. 성능은 판단 근거가 아니다 |
| 병행 운영 | 충돌하므로 불가능 |
| 학습 목적 | eBPF 데이터패스를 직접 다뤄보는 것이 목적 중 하나 |

**병행이 불가능하다는 점이 결정적이었다.**
Cilium 을 쓰면서 kube-proxy 를 남겨두면 충돌이 발생한다.
둘 중 하나를 골라야 하고, Cilium 을 고른 이상 replacement 가 맞다.

### 실제로 겪은 것

구축 과정의 트러블슈팅 8건 중 3건이 eBPF 관련이었다.

| 번호 | 문제 | 원인 |
| --- | --- | --- |
| [04](../troubleshooting/04-kube-proxy-ipvs-conflict.md) | Service 접속 불가 | kube-proxy IPVS 와 eBPF 병행 |
| [05](../troubleshooting/05-apiserver-sg-kpr.md) | Service 접속 불가 | eBPF 직접 변환으로 SG 요구사항 변화 |
| [07](../troubleshooting/07-iptables-corruption-l7.md) | L7 정책 미동작 | iptables 직접 조작 |

**세 건 모두 eBPF 데이터패스를 이해하지 못한 상태에서
익숙한 방식으로 접근한 것이 원인이었다.**

현재 규모에서 성능 이점은 체감되지 않는다.
얻은 것은 관측성과 학습이고, 치른 비용은 디버깅 시간이었다.

### 우리 구성

| 항목 | 값 |
| --- | --- |
| kube-proxy | 제거 (`kube_proxy_remove: true`) |
| kubeProxyReplacement | true |
| 터널 모드 | VXLAN |
| XDP / DSR | 미사용. 남북 트래픽 규모가 작다 |
| L7 정책 | 미적용. `cilium-envoy` 는 대기 상태 |

**L7 정책을 아직 만들지 않은 이유는 적용할 대상이 없어서다.**
L7 정책은 "어떤 Pod 가 어떤 HTTP 경로를 호출하는가" 를 제어하는데,
현재 클러스터에는 서로 호출하는 컴포넌트가 없다.

애플리케이션 배포 후 API 스펙이 확정되면 경로 단위 규칙을 정의한다.

구체적인 설정값은 [docs/06-kubespray.md](../06-kubespray.md) 참조.
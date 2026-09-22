# CNI — Kubernetes Pod 네트워킹

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| CNI 스펙 | https://github.com/containernetworking/cni/blob/main/SPEC.md |
| Kubernetes 네트워크 모델 | https://kubernetes.io/docs/concepts/cluster-administration/networking/ |
| CNI 플러그인 목록 | https://kubernetes.io/docs/concepts/cluster-administration/addons/ |
| Cilium | https://docs.cilium.io/ |
| Cilium 시스템 요구사항 | https://docs.cilium.io/en/stable/operations/system_requirements/ |
| Calico | https://docs.tigera.io/calico/latest/about/ |
| Calico 네트워킹 옵션 비교 | https://docs.tigera.io/calico/latest/networking/determine-best-networking |
| Flannel | https://github.com/flannel-io/flannel |

---

## CNI 란 무엇인가

**Container Network Interface.** 컨테이너에 네트워크를 연결하는 방법을 정의한 규격이다.

Kubernetes 자체는 Pod 에 IP 를 부여하거나 노드 간 경로를 만드는 코드를 갖고 있지 않다.
대신 "이런 조건을 만족하는 무언가를 붙여라" 라고 요구사항만 정의하고,
실제 구현은 CNI 플러그인에 위임한다.

### Kubernetes 가 요구하는 네트워크 모델

세 가지 조건이다.

| 조건 | 의미 |
| --- | --- |
| 모든 Pod 가 고유 IP 를 가진다 | NAT 없이 서로를 IP 로 식별할 수 있다 |
| Pod 간 통신에 NAT 가 없다 | A 가 보낸 패킷을 B 는 A 의 IP 로 받는다 |
| 노드와 Pod 가 서로 통신 가능하다 | 노드의 에이전트가 Pod 에 접근할 수 있다 |

Docker 의 기본 브리지 네트워크는 이 조건을 만족하지 않는다.
컨테이너가 호스트별로 같은 대역(`172.17.0.0/16`)을 쓰고 포트 매핑과 NAT 에 의존하기 때문이다.

CNI 플러그인은 **이 조건을 만족하는 네트워크를 만드는 역할**을 한다.

### CNI 가 하는 일

kubelet 이 Pod 를 만들 때 CNI 플러그인을 호출한다.

```
kubelet
  │ Pod 생성 요청
  ▼
CNI 플러그인
  ├─ IP 주소 할당 (IPAM)
  ├─ 네트워크 인터페이스 생성 (veth pair)
  ├─ Pod 네임스페이스에 인터페이스 연결
  ├─ 라우팅 테이블 설정
  └─ (구현체에 따라) NetworkPolicy 적용
```

플러그인은 `/opt/cni/bin` 에 바이너리로 존재하고,
설정은 `/etc/cni/net.d` 에 JSON 으로 놓인다.
kubelet 은 이 경로를 읽어 플러그인을 실행한다.

> 우리 환경에서 `/opt/cni/bin` 소유자 문제로 Cilium 이 기동하지 못한 사례가 있다.
> [troubleshooting/03](../troubleshooting/03-cilium-cni-bin-permission.md) 참조.

---

## 노드 간 Pod 통신을 어떻게 만드는가

Pod 는 노드 안에서만 존재하는 가상 인터페이스를 갖는다.
다른 노드의 Pod 로 패킷을 보내려면 **노드 사이를 건너는 방법**이 필요하다.

여기서 CNI 구현체들이 갈린다. 크게 두 가지 방식이 있다.

### Overlay — 캡슐화

원래 패킷을 다른 패킷으로 감싸서 노드 간에 전달한다.

```
Pod A (10.244.0.5)                      Pod B (10.244.1.7)
   │                                          ▲
   ▼                                          │
노드 1 (10.20.10.20)                    노드 2 (10.20.11.20)
   │                                          ▲
   │  [ 외부 헤더: 10.20.10.20 → 10.20.11.20 ] │
   │  [ 내부 패킷: 10.244.0.5 → 10.244.1.7   ] │
   └──────────────────────────────────────────┘
              물리 네트워크는 바깥 헤더만 본다
```

물리 네트워크(AWS VPC 라우터 등)는 Pod IP 를 알 필요가 없다.
노드 IP 만 보고 전달하면 되고, 도착한 노드가 껍데기를 벗겨 Pod 에 넘긴다.

| 항목 | 내용 |
| --- | --- |
| 프로토콜 | VXLAN (UDP 8472), Geneve, IP-in-IP |
| 장점 | 물리 네트워크 요구사항이 없다. IP 연결만 되면 동작한다 |
| 단점 | 헤더가 추가되어 MTU 가 줄고 캡슐화·복호화 비용이 든다 |

**AWS 멀티 서브넷 환경에서는 사실상 필수다.**
VPC 라우터는 라우팅 테이블에 없는 대역을 전달하지 않으므로,
캡슐화 없이는 서브넷이 다른 노드 간 Pod 통신이 드롭된다.

### Native routing — 캡슐화 없음

Pod IP 를 물리 네트워크가 직접 라우팅한다.

```
Pod A (10.244.0.5) ──→ 노드 1 ──→ [ 라우터: 10.244.1.0/24 는 노드 2 로 ] ──→ 노드 2 ──→ Pod B
```

각 노드가 "내 뒤에 이 Pod 대역이 있다" 를 라우터에 알려야 한다.
BGP 같은 라우팅 프로토콜을 쓰거나, 같은 L2 도메인이면 정적 경로로도 가능하다.

| 항목 | 내용 |
| --- | --- |
| 장점 | 캡슐화 오버헤드가 없다. MTU 손실이 없고 패킷 처리가 단순하다 |
| 단점 | 물리 네트워크가 Pod 대역을 라우팅할 수 있어야 한다 |

AWS VPC 에서도 가능하지만 제약이 있다.
VPC 라우팅 테이블에 Pod 대역 경로를 직접 넣거나,
AWS VPC CNI 처럼 Pod 에 VPC IP 를 직접 부여하는 방식을 써야 한다.

### 정리

| | Overlay | Native routing |
| --- | --- | --- |
| 물리 네트워크 요구사항 | 없음 | Pod 대역 라우팅 필요 |
| 성능 | 캡슐화 비용 | 더 빠름 |
| MTU | 헤더만큼 감소 | 영향 없음 |
| 디버깅 | 캡슐 안을 봐야 함 | 일반 도구로 가능 |
| 적합한 환경 | 클라우드, 혼합 인프라 | 온프레미스, BGP 가능한 환경 |

---

## 대표 구현체

CNI 구현체는 수십 가지가 있으나, **설계 철학이 다른 세 가지**를 비교하면
전체 지형이 드러난다.

| 구현체 | 데이터패스 | 위치 |
| --- | --- | --- |
| Flannel | VXLAN 오버레이 | 연결성만 제공하는 가장 단순한 형태 |
| Calico | iptables (eBPF 등 선택 가능) | 라우팅과 정책을 갖춘 범용 선택지 |
| Cilium | eBPF | 커널 프로그래밍 기반, 신규 채택이 늘어나는 흐름 |

그 외에 Weave Net, Antrea, Kube-router, Multus(다중 인터페이스),
그리고 클라우드 제공자의 AWS VPC CNI, Azure CNI 등이 있다.
클라우드 CNI 는 Pod 에 VPC IP 를 직접 부여해 네이티브 통합을 제공하나
IP 고갈과 노드당 Pod 수 제한이라는 제약이 따른다.

---

### Flannel

가장 단순하다. **Pod 간 연결만 만들어준다.**

VXLAN 오버레이로 노드 간 경로를 만들고, 그 외에는 거의 아무것도 하지 않는다.
설정 항목이 적고 에이전트가 하는 일도 적다.

| 장점 | 단점 |
| --- | --- |
| 설정 항목이 적다 | **NetworkPolicy 를 지원하지 않는다** |
| 리소스 소비가 가장 적다 | 암호화 기능이 없다 |
| 경량 배포판의 기본값 | 관측성 기능이 없다 |
| | L7 정책, 로드밸런싱 등 고급 기능 부재 |

**NetworkPolicy 미지원이 결정적인 제약이다.**
Pod 간 통신을 제어할 수 없으므로 클러스터 안에서 모든 Pod 가 서로에게 도달 가능하다.
격리가 필요한 환경에서는 쓸 수 없다.

k3s 같은 배포판은 별도의 NetworkPolicy 컨트롤러를 함께 번들해 이를 보완하기도 한다.

**적합한 경우** — 학습용 클러스터, 단일 테넌트 내부 도구,
리소스가 극히 제한된 엣지 환경.

---

### Calico

L3 라우팅 중심으로 설계되었고 **NetworkPolicy 를 처음부터 지원**했다.

BGP 로 각 노드가 자신이 보유한 Pod 대역을 라우터에 알린다.
라우터가 그 경로를 학습하면 Pod IP 를 직접 라우팅할 수 있어 캡슐화가 필요 없다.
물리 네트워크 장비와 BGP 피어링하면 Pod 대역이 그대로 라우팅된다.
BGP 를 쓸 수 없는 환경에서는 IP-in-IP 나 VXLAN 오버레이로 전환한다.

**데이터플레인을 선택할 수 있다는 점이 특징이다.**
공식 문서 기준으로 Open Source 에디션이 다섯 가지를 지원한다.

| 데이터플레인 | 비고 |
| --- | --- |
| iptables | 기본값 |
| nftables | iptables 후속 |
| eBPF | 나중에 추가된 선택지 |
| Windows | Windows 노드용 |
| VPP | 고성능 사용자 공간 데이터패스 |

| 장점 | 단점 |
| --- | --- |
| Native routing 으로 오버헤드 최소화 | BGP 운영 지식이 필요하다 |
| 데이터플레인 선택 폭이 넓다 | iptables 모드는 정책이 많아지면 성능이 저하된다 |
| **Windows 노드를 지원한다** | CNCF 프로젝트가 아니다 (Tigera 가 유지) |
| 표준 Linux 도구로 디버깅 가능 | |
| WireGuard 암호화를 Open Source 에서 제공 | |

**iptables 모드의 성능 특성**을 이해해야 한다.
규칙이 선형으로 평가되므로 NetworkPolicy 수가 늘면 지연이 증가한다.
eBPF 나 nftables 데이터플레인으로 전환하면 완화된다.

**Windows 지원은 다른 두 구현체에 없는 강점이다.**
.NET 워크로드와 Linux 마이크로서비스를 함께 운영하는 환경에서는
사실상 유일한 선택지다.

관측성은 Open Source 에 **Calico Whisker** 웹 콘솔이 포함되어 flow log 를 조회할 수 있다.
더 깊은 분석(서비스 그래프, 패킷 캡처, 히스토리 보존)은 상용 에디션 영역이다.

**적합한 경우** — 온프레미스 데이터센터, BGP 인프라가 있는 환경,
Windows 컨테이너가 필요한 조직, 기존 네트워크와의 통합이 중요한 경우.

---

### Cilium

**eBPF 를 전제로 처음부터 설계**되었다.
Calico 가 eBPF 를 나중에 추가한 것과 구조적으로 다르다.

패킷 처리, 정책 적용, 로드밸런싱이 모두 커널 안의 eBPF 프로그램으로 이뤄진다.
iptables 체인을 거치지 않으므로 규칙 수와 무관하게 성능이 유지된다.

kube-proxy 를 완전히 대체할 수 있고(`kube-proxy replacement`),
Hubble 이라는 관측성 계층이 내장되어 있다.

| 장점 | 단점 |
| --- | --- |
| 정책 수가 늘어도 성능이 유지된다 | **기능별로 커널 버전 요구사항이 다르다** |
| **L7 정책** (HTTP 경로·메서드 단위) | 디버깅에 전용 도구가 필요하다 |
| Hubble 로 흐름 관측이 내장 | Windows 미지원 |
| kube-proxy 제거 가능 | |
| 사이드카 없는 mTLS 지원 | |
| CNCF Graduated (2023-10) | |

#### 커널 요구사항

공식 문서 기준 **에이전트 동작 자체의 최소 커널은 그리 높지 않다.**
문제는 기능별로 요구 버전이 다르다는 점이다.

| 대상 | 요구 |
| --- | --- |
| 기본 동작 | 배포 버전에 따라 4.19 대 |
| kube-proxy replacement | 더 높은 버전 필요 (5.x 대) |
| eBPF 호스트 라우팅 등 | 추가 요구사항 |

**쓰려는 기능의 요구사항을 개별로 확인해야 한다.**
"Cilium 을 설치할 수 있다" 와 "이 기능을 쓸 수 있다" 가 다르다.
정확한 표는 공식 시스템 요구사항 문서를 참조한다.

#### 디버깅 방식의 차이

**이것이 가장 큰 트레이드오프다.**

`iptables -L` 로 규칙을 확인하던 방식이 통하지 않는다.
`cilium-dbg bpf lb list` 같은 전용 명령을 써야 하고,
eBPF 맵의 상태를 읽을 줄 알아야 한다.

문제가 생겼을 때 참조할 수 있는 자료도 iptables 만큼 많지 않다.

**적합한 경우** — 클라우드 환경, 정책이 많거나 서비스 수가 많은 클러스터,
L7 단위 제어가 필요한 경우, 관측성이 중요한 경우.

---

## 생태계 동향

주요 관리형 Kubernetes 가 Cilium 기반 데이터플레인을 선택지로 제공한다.
GKE Dataplane V2, Azure CNI Powered by Cilium, EKS Anywhere 가 그렇다.

다만 **기본값은 여전히 제공자마다 다르다.** EKS 의 기본 CNI 는 AWS VPC CNI 다.

kube-proxy 자체도 iptables 에서 벗어나는 중이다.
nftables 모드가 추가되었고 IPVS 백엔드는 deprecated 되었다.

Calico 도 eBPF 와 nftables 데이터플레인을 선택지로 제공한다.
방향성은 같고, 차이는 "처음부터 eBPF 로 설계했는가" 에 있다.

---

## 선택 기준

### 무엇을 먼저 보는가

```
1. NetworkPolicy 가 필요한가?
   아니오 → Flannel 도 가능
   예    → Calico 또는 Cilium

2. Windows 노드가 있는가?
   예    → Calico

3. 물리 네트워크가 BGP 를 지원하고 성능이 최우선인가?
   예    → Calico (BGP + native routing)

4. 쓰려는 기능의 커널 요구사항을 충족하는가?
   아니오 → Calico (iptables 또는 nftables)
   예    → Cilium

5. 관측성, L7 정책, 서비스 메시 기능이 필요한가?
   예    → Cilium
```

### 성능은 언제 문제가 되는가

일반적인 규모에서는 세 구현체의 차이가 크지 않다.
**정책 수와 서비스 수가 늘어날 때** 격차가 벌어진다.

| 상황 | iptables 기반 | eBPF 기반 |
| --- | --- | --- |
| 정책 수십 개 | 문제없음 | 문제없음 |
| 정책 수백 개 | 지연 증가 | 영향 없음 |
| 서비스 수천 개 | kube-proxy 규칙 폭증 | eBPF 맵으로 상수 시간 |

규모가 작다면 성능이 선택 기준이 되기 어렵다.
**운영 편의성과 필요한 기능**이 더 중요한 판단 근거다.

---

## 우리의 선택 — Cilium

| 기준 | 판단 |
| --- | --- |
| NetworkPolicy | 필요. 보안 대시보드 프로젝트이므로 정책 제어가 주제와 직결된다 |
| Windows | 불필요 |
| BGP | AWS VPC 에서 사용할 수 없다. Native routing 이점이 없다 |
| 커널 | Ubuntu 24.04, 커널 7.0. kube-proxy replacement 요구사항 충족 |
| 관측성 | Hubble 내장이 별도 도구 도입보다 유리하다 |
| L7 정책 | HTTP 경로 단위 제어를 실험할 계획이 있다 |

**AWS 환경이라 Calico 의 BGP 이점을 쓸 수 없다는 점이 컸다.**
어차피 오버레이를 써야 한다면 Calico 의 주요 강점 하나가 사라진다.

그 상태에서 관측성과 L7 정책을 고려하면 Cilium 쪽으로 기운다.

### 감수한 것

**디버깅 난이도가 실제로 문제가 되었다.**

구축 과정에서 겪은 문제 중 상당수가 Cilium 관련이었다.

| 문제 | 원인 |
| --- | --- |
| [04](../troubleshooting/04-kube-proxy-ipvs-conflict.md) | kube-proxy IPVS 와 eBPF 가 같은 Service 를 처리해 충돌 |
| [05](../troubleshooting/05-apiserver-sg-kpr.md) | eBPF 가 Service IP 를 직접 변환해 SG 요구사항이 달라짐 |
| [07](../troubleshooting/07-iptables-corruption-l7.md) | iptables 직접 조작이 Cilium 내부 상태를 손상 |

세 건 모두 **"iptables 기반이었다면 다르게 나타났을" 문제**다.
eBPF 데이터패스를 이해하지 못한 상태에서 익숙한 방식으로 접근한 것이 원인이었다.

정책 수십 개 수준의 클러스터라면 Calico 로도 충분했을 것이다.
Cilium 을 고른 것은 성능보다 **관측성과 L7 제어, 그리고 학습 목적**이 컸다.

### 우리 구성

| 항목 | 값 | 이유 |
| --- | --- | --- |
| 터널 모드 | VXLAN | AWS 멀티 서브넷. 캡슐화 필수 |
| kube-proxy | replacement | 병행 시 충돌 |
| Pod CIDR | 10.244.0.0/16 | VPC 대역과 분리 |
| Hubble | Relay 설치, UI 제외 | 흐름 조회는 CLI 로 |

구체적인 설정값은 [docs/06-kubespray.md](../06-kubespray.md) 참조.
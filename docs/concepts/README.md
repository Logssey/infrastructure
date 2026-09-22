# 개념 정리

`docs` 가 "이 프로젝트를 어떻게 구축했는가" 를 다룬다면,
이 디렉터리는 "그 기술이 무엇이고 왜 그것을 골랐는가" 를 다룬다.

## 작성 기준

모든 개념을 다루지 않는다. 아래 조건에 해당하는 것만 쓴다.

- 구축 과정에서 실제로 막혔던 영역
- 대안이 여럿이라 선택에 근거가 필요했던 영역
- 개념을 모르면 트러블슈팅 기록을 따라가기 어려운 영역

단순히 쓰면 되는 것은 제외한다.
Service 타입이나 Helm 사용법처럼 선택의 여지가 없거나 공식 문서로 충분한 내용은 구현 문서에서 짧게 언급한다.

## 목록

| 문서 | 내용 |
| --- | --- |
| [ansible.md](ansible.md) | 멱등성, 인벤토리, 플레이북. 언제 쓰고 언제 쓰지 않는가 |
| [kubespray.md](kubespray.md) | 클러스터 구축 도구 비교. kubeadm, 관리형 서비스와의 관계 |
| [etcd.md](etcd.md) | 합의 알고리즘, quorum, stacked 와 external 토폴로지 |
| [cni.md](cni.md) | Pod 네트워킹 원리, Overlay 와 Native routing, CNI 구현체 비교 |
| [ebpf.md](ebpf.md) | 커널 데이터패스, kube-proxy 대체, iptables·IPVS 와의 차이 |
| [gateway-api.md](gateway-api.md) | Ingress 의 한계와 Gateway API, 구현체 선택 |

## 읽는 순서

의존 관계가 있다.

```
ansible → kubespray → etcd

cni → ebpf → gateway-api
```

두 줄기는 독립적이다. 클러스터를 어떻게 만드는가와
그 위에서 네트워크가 어떻게 동작하는가로 나뉜다.

## 구현 문서와의 관계

개념 문서는 이 프로젝트에 종속되지 않는다.
다른 환경에서도 유효한 내용만 담고, 우리 선택은 예시로 든다.

구체적인 설정값과 구축 절차는 구현 문서를 참조한다.

| 개념 | 구현 |
| --- | --- |
| ansible, kubespray, etcd | [06-kubespray.md](../06-kubespray.md) |
| cni, ebpf | [06-kubespray.md](../06-kubespray.md), [02-security.md](../02-security.md) |
| gateway-api | [07-ingress.md](../07-ingress.md) |
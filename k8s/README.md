# Kubernetes 애드온

클러스터에 설치하는 플랫폼 컴포넌트의 Helm values 를 관리한다.

## 구조

```
k8s/
  platform/           클러스터 공통 컴포넌트
    metrics-server/
```

애플리케이션 매니페스트는 별도 저장소에서 관리한다.

## 설치 목록

| 컴포넌트 | 차트 버전 | 앱 버전 | 네임스페이스 |
| --- | --- | --- | --- |
| metrics-server | 3.14.0 | 0.9.0 | kube-system |

## 설치 방법

Control Plane 1번 노드(cp-a)에서 실행한다.
현재는 values 파일을 노드에 직접 작성해 설치한다.
Argo CD 도입 후에는 이 디렉터리를 소스로 사용한다.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm install metrics-server metrics-server/metrics-server \
  --version 3.14.0 -n kube-system \
  -f values.yaml
```

**설치 전 렌더링 결과를 확인한다.**

```bash
helm template <name> <chart> --version <ver> -n <ns> -f values.yaml
```

차트마다 `defaultArgs` 와 `args` 를 다루는 방식이 다르다.
값이 추가되는지 덮어쓰는지, 지정한 키가 실제로 반영되는지 확인해야 한다.

## 전제 조건

### kubelet serving certificate

metrics-server 는 kubelet 인증서가 클러스터 CA 로 서명되어 있어야 한다.
그렇지 않으면 `--kubelet-insecure-tls` 로 검증을 꺼야 하는데, 공식 문서는
이를 테스트 용도로만 권장한다.

Kubespray 인벤토리에 아래가 설정되어 있다.

```yaml
kubelet_rotate_server_certificates: true

kubelet_csr_approver_values:
  providerRegex: "^(cp|worker)-[acd]$"
  providerIpPrefixes:
    - "10.20.0.0/16"
  bypassDnsResolution: true
  maxExpirationSeconds: "86400"
```

`kubelet_rotate_server_certificates` 를 켜면 kubelet 이 클러스터 CA 에 CSR 을
요청하고, kubelet-csr-approver 가 자동 설치되어 승인을 처리한다.

approver 는 기본적으로 노드 DNS 이름 해석을 검증하나 본 환경의 노드명은
DNS 에 등록되어 있지 않다. DNS 검증을 끄는 대신 호스트명 정규식과
VPC IP 대역으로 승인 범위를 제한한다.

확인.

```bash
kubectl get csr
# 노드 6대 Approved,Issued

ansible -i <inventory> cp-a -m shell -b \
  -a "openssl x509 -in /var/lib/kubelet/pki/kubelet-server-current.pem \
      -noout -issuer -ext subjectAltName"
# issuer=CN = kubernetes
# DNS:cp-a, IP Address:10.20.10.10
```

상세는 `kubespray/README.md` 참조.

### Security Group

kubelet API(10250) 경로가 열려 있어야 한다.

| 출발지 | 목적지 | 용도 |
| --- | --- | --- |
| sg-control-plane | sg-worker | apiserver → Worker Pod |
| sg-control-plane | sg-control-plane | apiserver → CP Pod |
| sg-worker | sg-control-plane | metrics-server → CP kubelet |
| sg-worker | sg-worker | metrics-server → Worker kubelet |

컴포넌트를 추가하기 전에 필요한 통신 경로를 먼저 검토한다.
상세는 `docs/02-security.md` 와 `docs/troubleshooting/06-kubelet-api-sg.md` 참조.

## 검증

```bash
kubectl top nodes
```

노드 6대 전부 값이 나와야 한다. `<unknown>` 이 있으면 해당 노드의
kubelet 접근 경로를 확인한다.

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=metrics-server \
  --since=1m | grep "Failed to scrape"
```

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
# AVAILABLE True
```
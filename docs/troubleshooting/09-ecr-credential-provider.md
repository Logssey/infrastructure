# 09. ECR 이미지 pull 실패 — kubelet 자격증명 공급자 부재

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-26 |
| 단계 | Argo CD 최초 배포 (`reused-api`) |
| 영향 | 모든 Worker 에서 ECR 이미지 pull 불가. 배포 전면 중단 |
| 환경 | Kubespray v2.31.0, Kubernetes 1.35.4, Ubuntu 24.04 |

## 증상

Argo CD 가 `reused-api` 를 배포했으나 Pod 가 `ImagePullBackOff` 에서 멈췄다.

```bash
kubectl -n reused describe pod -l app.kubernetes.io/name=reused-api | grep -A5 "Events:"
```

```
Normal   Scheduled  37s                default-scheduler  Successfully assigned
                                                          reused/reused-api-ff76bfb8b-gdc7p to worker-d
Normal   Pulling    21s (x2 over 37s)  kubelet  Pulling image "794386801311.dkr.ecr...
Warning  Failed     21s (x2 over 37s)  kubelet  Failed to pull image "...":
  failed to resolve image: pull access denied, repository does not exist or
  may require authorization: authorization failed: no basic auth credentials
```

두 Pod 모두 같은 메시지였다. worker-c 와 worker-d 에 각각 스케줄됐으니
특정 노드 문제가 아니었다.

**`no basic auth credentials`** 가 핵심이다.
저장소가 없는 게 아니라 인증 정보를 제시하지 못한 것이다.

이미지 태그는 정상이었다.

```bash
kubectl -n reused get pod -l app.kubernetes.io/name=reused-api \
  -o jsonpath='{.items[0].spec.containers[0].image}'
# 794386801311.dkr.ecr.ap-northeast-1.amazonaws.com/logssey/reused-api:41e0a2fc...
```

노드 IAM Role 에는 `AmazonEC2ContainerRegistryReadOnly` 가 붙어 있었다.
권한은 있는데 kubelet 이 그것을 쓰지 못하고 있었다.

## 진단 과정

### 1. 자격증명 공급자 설정 확인

```bash
sudo ls -la /etc/kubernetes/ | grep -i credential
sudo grep -n "image-credential-provider\|imageCredentialProvider" \
  /etc/kubernetes/kubelet-config.yaml /var/lib/kubelet/kubeadm-flags.env 2>/dev/null
ls -la /usr/local/bin/ | grep -i ecr
```

**세 명령 모두 아무것도 출력하지 않았다.**

설정 파일도, kubelet 플래그도, 바이너리도 없었다.

### 2. kubelet 은 왜 스스로 인증하지 않는가

**Kubernetes 1.27 에서 in-tree ECR 자격증명 공급자가 제거되었다.**

| 버전 | 상태 |
| --- | --- |
| ~ 1.25 | kubelet 에 ECR·ACR·GCR 인증 로직이 내장 |
| 1.26 | 외부 자격증명 공급자 플러그인 GA (KEP-2133) |
| **1.27** | **in-tree 구현 제거** |

우리 클러스터는 1.35.4 다. 내장 로직이 사라진 지 여덟 버전이 지났다.

cloud provider extraction 의 일부다. 클라우드별 로직을 kubelet 본체에서 빼고
플러그인으로 돌리는 방향이며, 결과적으로 **비관리형 클러스터에서 ECR 을 쓰려면
플러그인을 직접 설치해야 한다.**

EKS 는 AMI 에 미리 넣어둔다(`/etc/eks/image-credential-provider/`).
직접 구축한 클러스터에는 그런 것이 없다.

### 3. Kubespray 가 처리하지 않는다

Kubespray 는 클라우드 중립적으로 설계되어 특정 벤더의 레지스트리 인증을
기본 제공하지 않는다. 관련 이슈가 2023 년에 올라왔으나 미지원 상태다.

## 원인

**1.27 에서 제거된 in-tree ECR 인증을 대체할 플러그인이 없었다.**

kubelet 은 ECR 주소를 봐도 어떤 자격증명을 써야 하는지 모른다.
노드 IAM Role 이 있어도 그것을 ECR 토큰으로 바꾸는 경로가 없어
익명 요청을 보내고 거부당한다.

```
kubelet ──이미지 pull──> ECR
   │
   └─ 자격증명? → (플러그인 없음) → 익명 → no basic auth credentials
```

## 대안 검토

| 안 | 내용 |
| --- | --- |
| **A. credential provider** | 표준 방식. 토큰 자동 갱신. 노드마다 설치 필요 |
| B. imagePullSecret | 설정은 간단하나 **ECR 토큰이 12시간마다 만료**. 갱신 CronJob 필요 |
| C. Kubespray 재실행 | 인벤토리에 kubelet extra args 추가. 전체 재실행에 시간 소요 |

**A 를 택했다.** B 는 토큰 만료 때문에 상시 운영 부담이 생기고,
C 는 이 작업 하나를 위해 클러스터 전체를 다시 돌리는 셈이다.

## 해결

### 1. 바이너리 버전 선택 — 여기서 막혔다

공식 배포 경로는 `artifacts.k8s.io` 다.
버전 정책상 **Kubernetes 버전과 맞춰야 한다.** 1.35 클러스터면 v1.35.x 다.

```bash
curl -sI https://artifacts.k8s.io/binaries/cloud-provider-aws/v1.35.0/linux/amd64/ecr-credential-provider-linux-amd64 | head -3
```

```
HTTP/2 404
```

없었다. 범위를 넓혀 찾았다.

```bash
for v in v1.35.0 v1.34.0 v1.33.0 v1.32.0 v1.31.0 v1.30.0; do
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    "https://artifacts.k8s.io/binaries/cloud-provider-aws/${v}/linux/amd64/ecr-credential-provider-linux-amd64")
  echo "$v : $code"
done
```

```
v1.35.0 : 404
v1.34.0 : 404
v1.33.0 : 404
v1.32.0 : 404
v1.31.0 : 200
v1.30.0 : 404
```

패치 버전과 상위 버전도 확인했다.

```
v1.35.2 : 404
v1.35.1 : 404
v1.36.1 : 404
v1.37.0 : 200
```

**GitHub 릴리스에는 존재하는데 `artifacts.k8s.io` 에는 게시되지 않은 버전이 많다.**
같은 문제가 이슈로 올라와 있다(cloud-provider-aws#1324).

받을 수 있는 것은 v1.31.0 과 v1.37.0 둘뿐이었다.

| 버전 | 판단 |
| --- | --- |
| **v1.37.0** | 클러스터보다 앞섬. 최신 API 지원 |
| v1.31.0 | 클러스터보다 뒤짐 |

**v1.37.0 을 택했다.** 자격증명 공급자는 kubelet 과 stdio 로 통신하는
단순한 플러그인이라 호환 폭이 넓고, API 버전(`credentialprovider.kubelet.k8s.io/v1`)만
맞으면 된다. 앞선 버전이 뒤진 것보다 안전하다.

대안 경로도 있다. staging 버킷은 더 많은 버전을 보관한다.

```
https://storage.googleapis.com/k8s-staging-provider-aws/releases/v<VERSION>/linux/amd64/ecr-credential-provider-linux-amd64
```

### 2. 다운로드

cp-a 에서 받아 Worker 로 배포한다. Worker 는 인터넷 egress 가 NAT 를 거치므로
어느 쪽에서 받아도 되지만, 한 번 받아 복사하는 편이 빠르다.

```bash
cd /tmp
curl -LO https://artifacts.k8s.io/binaries/cloud-provider-aws/v1.37.0/linux/amd64/ecr-credential-provider-linux-amd64
ls -lh ecr-credential-provider-linux-amd64
file ecr-credential-provider-linux-amd64
```

```
-rw-rw-r-- 1 ubuntu ubuntu 14M Sep 25 13:33 ecr-credential-provider-linux-amd64
ecr-credential-provider-linux-amd64: ELF 64-bit LSB executable, x86-64,
  statically linked, Go BuildID=..., stripped
```

정적 링크 Go 바이너리라 의존성이 없다.

### 3. Worker 3대에 설치

```bash
cd /tmp
for ip in 10.20.10.20 10.20.11.20 10.20.12.20; do
  echo "=== $ip ==="
  scp -q ecr-credential-provider-linux-amd64 ubuntu@$ip:/tmp/
  ssh ubuntu@$ip 'sudo install -m 0755 /tmp/ecr-credential-provider-linux-amd64 \
    /usr/local/bin/ecr-credential-provider && \
    rm /tmp/ecr-credential-provider-linux-amd64 && \
    ls -l /usr/local/bin/ecr-credential-provider'
done
```

```
=== 10.20.10.20 ===
-rwxr-xr-x 1 root root 14385314 Sep 25 13:34 /usr/local/bin/ecr-credential-provider
=== 10.20.11.20 ===
-rwxr-xr-x 1 root root 14385314 Sep 25 13:34 /usr/local/bin/ecr-credential-provider
=== 10.20.12.20 ===
-rwxr-xr-x 1 root root 14385314 Sep 25 13:34 /usr/local/bin/ecr-credential-provider
```

`install` 이 복사와 권한 설정을 한 번에 처리한다.

### 4. CredentialProviderConfig 생성

```bash
cd /tmp
cat > credential-provider-config.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "794386801311.dkr.ecr.ap-northeast-1.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF
```

**`name` 은 바이너리 파일명과 정확히 일치해야 한다.** kubelet 이 이 이름으로 실행한다.

**`matchImages` 를 계정·리전까지 좁혔다.**
공식 예시는 `*.dkr.ecr.*.amazonaws.com` 이지만 우리 레지스트리는 하나뿐이다.
와일드카드를 두면 다른 계정의 ECR 주소에도 플러그인이 호출되어
불필요한 API 요청과 실패 로그가 쌓인다.

패턴 매칭은 서브도메인 구획 단위다. `*.io` 는 `*.k8s.io` 와 매칭되지 않는다.

**`defaultCacheDuration: 12h`** 는 ECR 토큰 수명에 맞춘 값이다.
`0` 으로 두면 이미지를 받을 때마다 `GetAuthorizationToken` 을 호출한다.

세 노드에 배포한다.

```bash
for ip in 10.20.10.20 10.20.11.20 10.20.12.20; do
  echo "=== $ip ==="
  scp -q credential-provider-config.yaml ubuntu@$ip:/tmp/
  ssh ubuntu@$ip 'sudo install -m 0644 -o root -g root \
    /tmp/credential-provider-config.yaml /etc/kubernetes/credential-provider-config.yaml && \
    rm /tmp/credential-provider-config.yaml && \
    ls -l /etc/kubernetes/credential-provider-config.yaml'
done
```

### 5. kubelet 플래그 추가

Kubespray 의 kubelet 유닛은 인자를 환경 파일에서 읽는다.

```bash
sudo cat /etc/systemd/system/kubelet.service
```

```
[Service]
EnvironmentFile=-/etc/kubernetes/kubelet.env
ExecStart=/usr/local/bin/kubelet \
                "$KUBE_LOGTOSTDERR" \
                "$KUBE_LOG_LEVEL" \
                "$KUBELET_ARGS" \
                "$KUBELET_CLOUDPROVIDER"
```

**유닛 파일이 아니라 `/etc/kubernetes/kubelet.env` 를 고쳐야 한다.**

```bash
sudo cat /etc/kubernetes/kubelet.env
```

```
KUBELET_ARGS="--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
--config=/etc/kubernetes/kubelet-config.yaml \
--kubeconfig=/etc/kubernetes/kubelet.conf \
--runtime-cgroups=/system.slice/containerd.service \
 "
```

`--runtime-cgroups` 줄 뒤에 두 줄을 넣는다.

```bash
for ip in 10.20.10.20 10.20.11.20 10.20.12.20; do
  echo "=== $ip ==="
  ssh ubuntu@$ip "sudo cp /etc/kubernetes/kubelet.env /etc/kubernetes/kubelet.env.bak && \
    sudo sed -i 's|^--runtime-cgroups=/system.slice/containerd.service \\\\\$|--runtime-cgroups=/system.slice/containerd.service \\\\\n--image-credential-provider-config=/etc/kubernetes/credential-provider-config.yaml \\\\\n--image-credential-provider-bin-dir=/usr/local/bin \\\\|' /etc/kubernetes/kubelet.env"
done
```

**확인은 노드에 접속해서 해야 한다.**
`kubelet.env` 는 root 전용이라 `ssh ... 'grep ...'` 형태로는 읽히지 않는다.

```
grep: /etc/kubernetes/kubelet.env: Permission denied
```

```bash
ssh ubuntu@10.20.10.20
sudo cat /etc/kubernetes/kubelet.env
```

```
KUBELET_ARGS="--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
--config=/etc/kubernetes/kubelet-config.yaml \
--kubeconfig=/etc/kubernetes/kubelet.conf \
--runtime-cgroups=/system.slice/containerd.service \
--image-credential-provider-config=/etc/kubernetes/credential-provider-config.yaml \
--image-credential-provider-bin-dir=/usr/local/bin \
 "
```

두 플래그가 모두 있어야 한다. 하나만 있으면 kubelet 이 기동 시 거부한다.

### 6. kubelet 재시작 — 한 대씩

```bash
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager | head -5
```

**세 대를 동시에 재시작하지 않는다.** kubelet 이 멈춘 동안 그 노드는
상태 보고가 끊긴다. 한 대를 재시작하고 `Ready` 를 확인한 뒤 다음으로 넘어간다.

```bash
kubectl get nodes
```

## 검증

```bash
kubectl -n reused delete pod -l app.kubernetes.io/name=reused-api
kubectl -n reused get pods
```

```
reused-api-ff76bfb8b-xxxxx   1/1     Running   0     35s
reused-api-ff76bfb8b-yyyyy   1/1     Running   0     33s
```

플러그인 호출 여부는 kubelet 로그에서 확인한다.

```bash
sudo journalctl -u kubelet --since "5 min ago" | grep -i credential
```

## 재발 방지

**노드를 추가하거나 재생성하면 다시 설치해야 한다.**

| 시점 | 위험 |
| --- | --- |
| Worker 추가 | 새 노드에 플러그인 없음. 그 노드의 Pod 만 실패 |
| Kubespray 재실행 | `kubelet.env` 가 템플릿으로 덮어써져 **플래그 소실** |
| AMI 교체 | 바이너리 소실 |

**두 번째가 특히 위험하다.** 일부 노드만 실패하면 다른 노드에 Pod 가
스케줄되어 겉으로는 정상으로 보인다. Cilium CNI 바이너리 권한 문제와
같은 성격이다(`03-cilium-cni-bin-permission.md`).

근본 대응은 둘 중 하나다.

| 방안 | 내용 |
| --- | --- |
| Worker user_data 에 포함 | 기동 시 자동 설치. 노드 추가에 대응 |
| Kubespray 커스텀 태스크 | Ansible 재실행에도 유지 |

Worker user_data 쪽을 택한다. Kubespray 를 자주 재실행하지 않고
노드 추가가 더 잦기 때문이다.

다만 **Kubespray 재실행 후 확인 절차**를 `docs/06-kubespray.md` 의
실행 후 필수 작업에 추가한다.

```bash
# 각 Worker 에서
sudo grep -c "image-credential-provider" /etc/kubernetes/kubelet.env
# 2 가 나와야 한다
```

설정 파일 자체도 레포에 두어 재현할 수 있게 한다.

```
infrastructure/k8s/platform/ecr-credential-provider/credential-provider-config.yaml
```

## 참고

| 항목 | 내용 |
| --- | --- |
| in-tree 제거 | kubernetes/kubernetes#116329 |
| KEP-2133 | Kubelet Credential Providers |
| 공식 문서 | https://cloud-provider-aws.sigs.k8s.io/credential_provider/ |
| kubelet 설정 | https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/ |
| 바이너리 게시 누락 | cloud-provider-aws#1324 |
| 유사 사례 | `docs/troubleshooting/03-cilium-cni-bin-permission.md` |
| ECR 구성 | `docs/11-cicd.md` |
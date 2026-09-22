# 04. Service ClusterIP 접속 불가 — kube-proxy IPVS 충돌

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-21 |
| 단계 | 클러스터 기동 후 (노드 Ready 상태) |
| 영향 | CoreDNS·hubble-relay 기동 실패, 클러스터 DNS 전면 미동작 |
| 환경 | Kubespray v2.31.0, Cilium 1.19.3, kube-proxy IPVS 모드 |

## 증상

노드 6대는 모두 Ready 이고 Cilium agent 도 정상 기동했으나
CoreDNS 가 Ready 로 전환되지 않았다.

```
coredns-58cc5d8ddf-kp4kf        0/1   Running            0    14m
hubble-relay-6cf6b6fdf9-z4qlq   0/1   CrashLoopBackOff   11   47m
```

CoreDNS 로그.

```
[ERROR] plugin/kubernetes: Failed to watch
[INFO] plugin/ready: Plugins not ready: "kubernetes"
```

hubble-relay 로그.

```
msg="Failed to create peer notify client for peers change notification"
error="rpc error: code = Unavailable desc = dns: A record lookup error:
       lookup hubble-peer.kube-system.svc.cluster.local. on 169.254.25.10:53: server misbehaving"
```

CoreDNS 가 apiserver 에 붙지 못해 DNS 가 동작하지 않고,
그 결과 hubble-relay 가 이름 해석에 실패하는 연쇄 구조였다.

```
CoreDNS → apiserver 접근 불가
   ↓
DNS 미동작
   ↓
hubble-relay 이름 해석 실패
```

## 진단 과정

### 1. Pod 에서 Service IP 접속 테스트

```bash
kubectl run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c "wget -qO- --timeout=5 --no-check-certificate https://10.96.0.1:443/healthz 2>&1"
```

```
wget: download timed out
```

Service ClusterIP(`10.96.0.1`)로 apiserver 에 접근할 수 없다.

### 2. Cilium 이 인식하는 Service 확인

```bash
ansible -i inventory/logssey/inventory.ini worker-c -m shell -b \
  -a "CID=\$(crictl ps --name cilium-agent -q | head -1); crictl exec \$CID cilium-dbg service list"
```

```
ID   Frontend               Service Type   Backend
1    10.96.0.3:53/TCP       ClusterIP      1 => 10.244.1.135:53/TCP (maintenance)
5    10.96.225.23:443/TCP   ClusterIP      1 => 10.20.11.20:4244/TCP (active)
6    10.96.0.1:443/TCP      ClusterIP      1 => 10.20.10.10:6443/TCP (active)
                                           2 => 10.20.11.10:6443/TCP (active)
                                           3 => 10.20.12.10:6443/TCP (active)
```

**Cilium 은 `10.96.0.1:443` 을 정상 인식**하고 백엔드 3개도 active 다.

### 3. iptables 규칙 확인

```bash
ansible -i inventory/logssey/inventory.ini worker-c -m shell -b \
  -a "iptables -t nat -L KUBE-SERVICES -n | head -10"
```

```
Chain KUBE-SERVICES (2 references)
RETURN          0  --  127.0.0.0/8   0.0.0.0/0
KUBE-MARK-MASQ  0  -- !10.244.0.0/16 0.0.0.0/0  match-set KUBE-CLUSTER-IP dst,dst
KUBE-NODE-PORT  0  --  0.0.0.0/0     0.0.0.0/0  ADDRTYPE match dst-type LOCAL
ACCEPT          0  --  0.0.0.0/0     0.0.0.0/0  match-set KUBE-CLUSTER-IP dst,dst
```

개별 Service 규칙이 없고 `match-set KUBE-CLUSTER-IP` 형태다.

```bash
ansible -i inventory/logssey/inventory.ini worker-c -m shell -b \
  -a "iptables -t nat -L -n | grep -c ':443'"
```

```
0
```

**nat 테이블에 Service 포트 규칙이 없다.** ipset 기반이라는 뜻이다.

### 4. IPVS 테이블 확인

```bash
ansible -i inventory/logssey/inventory.ini worker-c -m shell -b \
  -a "ipvsadm -Ln | head -20"
```

```
TCP  10.96.0.1:443 rr
  -> 10.20.10.10:6443   Masq  1  0  0
  -> 10.20.11.10:6443   Masq  1  0  0
  -> 10.20.12.10:6443   Masq  1  0  0
TCP  10.96.0.3:53 rr
```

IPVS 에도 `10.96.0.1:443` 이 백엔드 3개와 함께 정상 등록되어 있다.

### 5. kube-proxy 모드 확인

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E "mode|scheduler"
```

```
scheduler: rr
mode: ipvs
```

```bash
ansible-inventory -i inventory/logssey/inventory.ini --host worker-c | grep kube_proxy_mode
```

```
"kube_proxy_mode": "ipvs",
```

**Kubespray 기본값이 `ipvs` 였다.**

## 원인

**Cilium eBPF 와 kube-proxy IPVS 가 동일한 Service 를 각자 처리하며 충돌했다.**

양쪽 모두 `10.96.0.1:443` 을 백엔드 3개로 올바르게 매핑하고 있었으나,
패킷이 실제로 어느 경로를 타는지 불분명해 전달에 실패했다.

Cilium 은 kube-proxy 와 병행할 경우 **iptables 모드를 전제**로 설계되어 있다.
IPVS 는 netfilter 훅과 conntrack 을 사용하는데, eBPF 가 그 이전 단계에서
패킷을 가로채면 IPVS 규칙에 도달하지 않는다.

## 시도한 조치와 결과

### iptables 모드로 전환 — 부분 해결

```bash
sed -i 's|^kube_proxy_mode: ipvs|kube_proxy_mode: iptables|' \
  inventory/logssey/group_vars/k8s_cluster/k8s-cluster.yml
```

`cluster.yml` 재실행 후에도 ConfigMap 은 `ipvs` 로 남아 있었다.
Kubespray 가 기존 ConfigMap 을 덮어쓰지 않는다.

```bash
kubectl -n kube-system get cm kube-proxy -o yaml > /tmp/kube-proxy-cm.yaml
sed -i 's/^\( *\)mode: ipvs/\1mode: iptables/' /tmp/kube-proxy-cm.yaml
kubectl apply -f /tmp/kube-proxy-cm.yaml

ansible -i inventory/logssey/inventory.ini k8s_cluster -m shell -b -a "ipvsadm -C"
kubectl -n kube-system rollout restart ds/kube-proxy
```

iptables 규칙은 정상 생성되었다.

```
KUBE-SVC-NPX46M4PTMTKRN6Y  6  --  0.0.0.0/0  10.96.0.1  /* default/kubernetes:https cluster IP */ tcp dpt:443
```

**그러나 Pod 에서의 접속은 여전히 실패했다.** 병행 구성 자체가 문제였다.

### kube-proxy replacement 로 전환 — 채택

```bash
sed -i 's/^cilium_kube_proxy_replacement: false/cilium_kube_proxy_replacement: true/' \
  inventory/logssey/group_vars/k8s_cluster/k8s-net-cilium.yml

cat >> inventory/logssey/group_vars/k8s_cluster/k8s-cluster.yml << 'EOF'
kube_proxy_remove: true
EOF
```

`cilium_kube_proxy_replacement: true` 만으로도 Kubespray 가
`addon/kube-proxy` 를 건너뛴다.

`roles/kubespray_defaults/defaults/main/main.yml`

```jinja
{%- elif kube_network_plugin == 'cilium' and (cilium_kube_proxy_replacement is defined and ...) -%}
{{ kubeadm_init_phases_skip_default + ["addon/kube-proxy"] }}
```

**기존 kube-proxy 는 수동으로 제거해야 한다.** Kubespray 는 신규 설치를
건너뛸 뿐 기존 리소스를 삭제하지 않는다.

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy

ansible -i inventory/logssey/inventory.ini k8s_cluster -m shell -b \
  -a "iptables-save | grep -v KUBE- | iptables-restore; ipvsadm -C 2>/dev/null"
```

> **이 명령은 사용하지 않는다.**
> 테이블 전체를 다시 적재하는 과정에서 Cilium 규칙의 참조 관계가 어긋나
> L7 정책이 동작하지 않게 되었다. 증상은 12시간 뒤 connectivity test 에서
> 드러났다. 상세는 [07](07-iptables-corruption-l7.md) 참조.
>
> kube-proxy 규칙 제거가 필요하면 노드를 재부팅한다.

`cluster.yml` 재실행 후 확인.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
```

```
KubeProxyReplacement:    True   [ens5   10.20.10.20 ... (Direct Routing)]
```

eBPF 로드밸런서에도 정상 등록되었다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list | head
```

```
10.96.0.1:443/TCP (1)   10.20.10.10:6443/TCP (5) (1)
10.96.0.1:443/TCP (2)   10.20.11.10:6443/TCP (5) (2)
10.96.0.1:443/TCP (3)   10.20.12.10:6443/TCP (5) (3)
```

**이 시점에도 접속은 실패했다.** 남은 원인은 [05번 문서](05-apiserver-sg-kpr.md) 참조.

## 설계 변경

당초 설계는 kube-proxy replacement 미적용이었다.

> Service 라우팅 전체가 eBPF 로 대체되어 장애 시 디버깅 경로가 달라진다.

**이 판단이 역효과를 냈다.** 병행 구성이 오히려 디버깅을 어렵게 만들었고,
iptables 와 eBPF 중 어느 쪽이 패킷을 처리하는지 추적하는 데 시간이 소요되었다.

커널 요구사항은 5.8 이상이며, 본 환경은 7.0.0-1012-aws 로 충족한다.

| 항목 | 병행 (당초) | replacement (변경) |
| --- | --- | --- |
| Service 처리 | iptables/IPVS + eBPF | eBPF 단일 |
| kube-proxy | 필요 | 불필요 |
| 디버깅 | 두 계층 확인 필요 | 한 계층 |

## 재발 방지

- `kubespray/group_vars/k8s_cluster/k8s-net-cilium.yml` 에 `cilium_kube_proxy_replacement: true` 기록
- `kubespray/group_vars/k8s_cluster/k8s-cluster.yml` 에 `kube_proxy_remove: true` 기록
- 신규 클러스터는 처음부터 replacement 로 구성되므로 kube-proxy 수동 제거 불필요
- `docs/06-kubespray.md` 의 Cilium 설정 절에 반영

## 교훈

**Kubespray 기본값이 CNI 선택과 맞지 않을 수 있다.**

`kube_proxy_mode: ipvs` 는 Kubespray 기본값이고 Calico 환경에서는 문제가 없으나,
Cilium 과는 충돌한다. CNI 를 변경할 때는 관련 기본값을 함께 검토해야 한다.

**ConfigMap 은 Kubespray 재실행으로 갱신되지 않는다.**
인벤토리 변수를 바꿔도 기존 ConfigMap 이 남아 있으면 적용되지 않으므로
직접 수정하거나 삭제 후 재생성해야 한다.

**`kubectl exec` 가 무한 대기하면** apiserver → kubelet → 컨테이너 경로에
문제가 있다는 신호다. 이때는 노드에서 `crictl exec` 로 우회한다.

```bash
CID=$(sudo crictl ps --name cilium-agent -q | head -1)
sudo crictl exec $CID cilium-dbg status --brief
```

## 참고

| 항목 | 경로 |
| --- | --- |
| kube-proxy skip 로직 | `roles/kubespray_defaults/defaults/main/main.yml` (45~60행) |
| Cilium 설정 | `inventory/*/group_vars/k8s_cluster/k8s-net-cilium.yml` |
| 후속 문제 | `docs/troubleshooting/05-apiserver-sg-kpr.md` |
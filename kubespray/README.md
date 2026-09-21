# Kubespray 인벤토리

Kubespray 샘플 인벤토리에서 **변경한 부분만** 기록한다.
샘플 전체를 복사하지 않는 이유는 Kubespray 버전마다 샘플이 바뀌어
병합이 번거로워지기 때문이다.

## 버전

| 항목 | 값 |
| --- | --- |
| Kubespray | v2.31.0 |
| Kubernetes | 1.35.4 |
| Cilium | 1.19.3 |
| containerd | 2.2.3 |

## 적용 절차

Control Plane 1번 노드(cp-a)에서 실행한다.

```bash
git clone --depth 1 --branch v2.31.0 https://github.com/kubernetes-sigs/kubespray.git
cd kubespray

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

cp -r inventory/sample inventory/logssey
```

이 디렉터리의 파일을 아래와 같이 반영한다.

| 이 저장소 | Kubespray 경로 | 방법 |
| --- | --- | --- |
| `inventory.ini` | `inventory/logssey/inventory.ini` | 전체 교체 |
| `group_vars/all/all.yml` | 동일 경로 | 파일 끝에 추가 |
| `group_vars/k8s_cluster/k8s-cluster.yml` | 동일 경로 | 기존 값 치환 + 끝에 추가 |
| `group_vars/k8s_cluster/k8s-net-cilium.yml` | 동일 경로 | 파일 끝에 추가 |

각 파일 상단 주석에 치환 대상이 적혀 있다.

### 기존 값 치환

```bash
cd inventory/logssey/group_vars/k8s_cluster

sed -i 's|^kube_network_plugin: calico|kube_network_plugin: cilium|' k8s-cluster.yml
sed -i 's|^kube_service_addresses: 10.233.0.0/18|kube_service_addresses: 10.96.0.0/16|' k8s-cluster.yml
sed -i 's|^kube_pods_subnet: 10.233.64.0/18|kube_pods_subnet: 10.244.0.0/16|' k8s-cluster.yml
```

### NLB 주소

`group_vars/all/all.yml` 의 NLB 주소는 환경마다 다르다.

```bash
cd terraform/environments/prod
terraform output -raw internal_api_dns_name
```

## 실행

```bash
ansible -i inventory/logssey/inventory.ini all -m ping
ansible-playbook -i inventory/logssey/inventory.ini cluster.yml -b
```

## 실행 후 필수 작업

**`/opt/cni/bin` 소유자를 root 로 변경한다.**

Kubespray 는 이 디렉터리를 `kube:root` 로 설정하나, Cilium 의
`mount-cgroup` init 컨테이너가 `DAC_OVERRIDE` 없이 root 로 실행되어
파일 쓰기가 거부된다. `cluster.yml` 을 돌릴 때마다 되돌아가므로
매번 수행해야 한다.

```bash
ansible -i inventory/logssey/inventory.ini k8s_cluster -m shell -b \
  -a "chown root:root /opt/cni/bin"

kubectl -n kube-system delete pods -l k8s-app=cilium
```

## 검증

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

kubectl get nodes
kubectl -n kube-system exec ds/cilium -- cilium-dbg status \
  | grep -E "KubeProxyReplacement|Routing|Cluster health"
```

| 항목 | 기대값 |
| --- | --- |
| 노드 | CP 3 + Worker 3 = 6대 Ready |
| KubeProxyReplacement | True |
| Routing | Tunnel [vxlan] |
| Cluster health | 6/6 reachable |

etcd 전용 노드는 Kubernetes 노드가 아니므로 `kubectl get nodes` 에 나타나지 않는다.

```bash
kubectl run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

## 커밋하지 않는 것

- `inventory/logssey/credentials/` — kubeadm 인증서 키
- `admin.conf`, kubeconfig — 클러스터 관리자 자격증명

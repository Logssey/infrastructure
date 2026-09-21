# 06. Kubespray 클러스터 구축

> 설계 근거는 Notion [4. Compute/Cluster] 참조

## 버전

| 항목 | 값 |
| --- | --- |
| Kubespray | v2.31.0 |
| Kubernetes | 1.35.4 |
| Cilium | 1.19.3 |
| containerd | 2.2.3 |
| Ansible | 11.13.0 (requirements.txt) |

`kube_version`을 명시하지 않으면 Kubespray가 아는 최신 버전이 적용된다.
재현성을 위해 인벤토리에 명시한다.

**버전 표기에 `v` 접두사를 붙이지 않는다.** v2.27부터 변경되었다.

## 실행 위치

Control Plane 1번 노드(cp-a)에서 Ansible을 실행한다.

| 항목 | 값 |
| --- | --- |
| 실행 노드 | logssey-prod-cp-a (10.20.10.10) |
| 접속 | SSM Session Manager |
| 대상 | 인벤토리의 9개 노드 (자기 자신 포함) |

별도 Management EC2를 두지 않는다. Ansible은 인벤토리에 정의된 노드에
SSH로 접속하므로 실행 노드가 클러스터 구성원이어도 무방하다.

`upgrade-cluster.yml`은 실행 노드 자신을 재구성하는 시점에 세션이
끊길 수 있으므로 `tmux` 등으로 실행한다.

## 인벤토리

| 그룹 | 노드 | 사설 IP |
| --- | --- | --- |
| kube_control_plane | cp-a / cp-c / cp-d | 10.20.10.10 / 10.20.11.10 / 10.20.12.10 |
| etcd | etcd-a / etcd-c / etcd-d | 10.20.20.10 / 10.20.21.10 / 10.20.22.10 |
| kube_node | worker-a / worker-c / worker-d | 10.20.10.20 / 10.20.11.20 / 10.20.12.20 |

Redis 노드(10.20.10.30)는 클러스터 구성원이 아니므로 인벤토리에 포함하지 않는다.

`[etcd]` 그룹이 `[kube_control_plane]`과 다른 호스트를 가리키므로
External etcd topology로 구성된다.

인벤토리 파일은 `kubespray/` 디렉터리에 변경분만 기록되어 있다.

## 주요 변수

### group_vars/all/all.yml

```yaml
loadbalancer_apiserver:
  address: <Internal NLB DNS>
  port: 6443

apiserver_loadbalancer_domain_name: <Internal NLB DNS>

# 외부 LB를 사용하므로 노드별 로컬 프록시를 비활성화한다.
# 기본값이 true이며, 켜두면 외부 LB 설정과 충돌한다.
loadbalancer_apiserver_localhost: false
```

`apiserver_loadbalancer_domain_name`을 지정해야 apiserver 인증서 SAN에
NLB 도메인이 포함된다. 없으면 NLB 주소로 접속할 때 TLS 검증이 실패한다.

### group_vars/k8s_cluster/k8s-cluster.yml

```yaml
kube_version: 1.35.4
container_manager: containerd

kube_network_plugin: cilium          # 기본값 calico 에서 변경
kube_pods_subnet: 10.244.0.0/16      # 기본값 10.233.64.0/18 에서 변경
kube_service_addresses: 10.96.0.0/16 # 기본값 10.233.0.0/18 에서 변경

kube_proxy_remove: true              # kube-proxy replacement 사용
```

**Pod/Service CIDR을 명시적으로 지정한다.**
Kubespray 기본값(`10.233.x`)은 VPC 대역(`10.20.0.0/16`)과 겹치지 않으나,
설계 문서의 값과 일치시켜 혼선을 방지한다.
클러스터 생성 후 변경은 사실상 재구축에 해당한다.

`cilium_kube_proxy_replacement: true`만으로도 Kubespray가 `addon/kube-proxy`를
건너뛰지만 의도를 명확히 하기 위해 함께 지정한다.

### group_vars/k8s_cluster/k8s-net-cilium.yml

```yaml
cilium_tunnel_mode: vxlan            # UDP 8472. 기본값이나 명시한다

cilium_kube_proxy_replacement: true

cilium_enable_hubble: true
cilium_hubble_install: true          # Relay 설치. 이것이 없으면 agent 기능만 켜진다
cilium_hubble_tls_generate: true     # Relay ↔ agent mTLS 인증서 자동 생성
cilium_enable_hubble_ui: false       # Relay 만 사용
```

**AWS 멀티 서브넷 환경에서는 캡슐화가 필수다.**
캡슐화 없는 라우팅 모드는 Pod 경로가 노드 커널 라우팅 테이블에만 등록되는데,
AWS VPC 라우터는 이를 인지하지 못해 Subnet이 다른 노드 간 통신이 드롭된다.

**`cilium_enable_hubble`만으로는 Relay가 설치되지 않는다.**
클러스터 전체 흐름을 조회하려면 `cilium_hubble_install`이 함께 필요하다.

#### kube-proxy replacement

당초 설계는 미적용이었다. "Service 라우팅 전체가 eBPF로 대체되어 장애 시
디버깅 경로가 달라진다"는 이유였으나, **병행 구성에서 Service ClusterIP 접속이
실패해 전환했다.**

iptables/IPVS 규칙과 Cilium eBPF가 같은 Service를 처리하며 충돌한 것으로 판단된다.
상세는 [troubleshooting/04](troubleshooting/04-kube-proxy-ipvs-conflict.md) 참조.

커널 요구사항은 5.8 이상이며 본 환경(7.0.0-1012-aws)은 충족한다.

**전환 시 SG 규칙이 추가로 필요하다.** eBPF가 Service IP를 Control Plane 노드로
직접 변환해 Internal NLB를 거치지 않는다.
상세는 [troubleshooting/05](troubleshooting/05-apiserver-sg-kpr.md) 참조.

---

## 실행 절차

### 1. cp-a 접속 및 SSH 키 생성

```bash
CP_A=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=logssey-prod-cp-a" "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target $CP_A --region ap-northeast-1
```

세션 안에서 ubuntu 사용자로 전환 후 키를 생성한다.

```bash
sudo su - ubuntu
ssh-keygen -t ed25519 -N "" -C "kubespray@cp-a" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub

# 자기 자신에게도 등록한다. 인벤토리에 cp-a 가 포함되기 때문이다.
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

출력된 공개키를 복사한다.

### 2. SSH 공개키 배포 — SSM Run Command

로컬 터미널에서 나머지 8대에 한 번에 배포한다.
SSM Run Command는 인스턴스에 명령을 원격 실행하는 기능으로,
SSH 접속 없이 공개키를 등록할 수 있다.

```bash
# 대상 인스턴스 ID 수집 (cp-a, redis 제외)
TARGETS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=logssey" \
            "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query "Reservations[].Instances[?Tags[?Key=='Role' && Value!='redis']].InstanceId" \
  --output text | tr '\t' '\n' | grep -v "<CP_A_INSTANCE_ID>")

echo "$TARGETS" | wc -l   # 8 이어야 한다
```

```bash
PUBKEY='ssh-ed25519 AAAA... kubespray@cp-a'   # 1단계에서 복사한 값

CMD_ID=$(aws ssm send-command \
  --region ap-northeast-1 \
  --document-name "AWS-RunShellScript" \
  --instance-ids $(echo $TARGETS | tr '\n' ' ') \
  --parameters commands="[
    \"mkdir -p /home/ubuntu/.ssh\",
    \"chmod 700 /home/ubuntu/.ssh\",
    \"touch /home/ubuntu/.ssh/authorized_keys\",
    \"grep -qxF '$PUBKEY' /home/ubuntu/.ssh/authorized_keys || echo '$PUBKEY' >> /home/ubuntu/.ssh/authorized_keys\",
    \"chmod 600 /home/ubuntu/.ssh/authorized_keys\",
    \"chown -R ubuntu:ubuntu /home/ubuntu/.ssh\"
  ]" \
  --comment "Distribute kubespray SSH public key" \
  --query 'Command.CommandId' --output text)

echo $CMD_ID
```

`grep -qxF ... ||` 조건으로 중복 등록을 방지한다. 재실행해도 안전하다.

실행 결과 확인.

```bash
aws ssm list-command-invocations \
  --command-id $CMD_ID \
  --region ap-northeast-1 \
  --query 'CommandInvocations[].[InstanceId,Status]' \
  --output table
```

8대 전부 `Success` 여야 한다.

### 3. SSH 접속 검증

Run Command 성공이 SSH 접속 성공을 보장하지 않는다. 여기서 확인해두면
이후 실패 시 원인 범위가 좁아진다.

```bash
for ip in 10.20.11.10 10.20.12.10 \
          10.20.20.10 10.20.21.10 10.20.22.10 \
          10.20.10.20 10.20.11.20 10.20.12.20; do
  printf "%-14s " "$ip"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
      ubuntu@$ip hostname 2>&1 | tail -1
done
```

8대 전부 호스트명이 출력되어야 한다.

### 4. Kubespray 클론 및 환경 구성

cp-a 세션에서 진행한다.

```bash
git clone --depth 1 --branch v2.31.0 https://github.com/kubernetes-sigs/kubespray.git
cd kubespray

sudo apt update && sudo apt install -y python3-venv python3-pip tmux
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

ansible --version
```

Ansible은 Kubespray가 `requirements.txt`로 버전을 고정하므로
전역 설치하지 않고 venv에 설치한다.

### 5. 인벤토리 작성

```bash
cp -r inventory/sample inventory/logssey
```

`kubespray/README.md`의 절차에 따라 인벤토리와 `group_vars`를 편집한다.

```bash
ansible-inventory -i inventory/logssey/inventory.ini --graph
```

`[etcd]`가 `[k8s_cluster]` 밖에 있어야 External etcd 구성이다.

### 6. 소통 확인

```bash
ansible -i inventory/logssey/inventory.ini all -m ping
ansible -i inventory/logssey/inventory.ini all -m command -a "id" -b
```

9대 전부 `SUCCESS`, `uid=0(root)` 여야 한다.

### 7. 클러스터 구축

```bash
ansible-playbook -i inventory/logssey/inventory.ini cluster.yml -b \
  -e unsafe_show_logs=true 2>&1 | tee /tmp/cluster.log
```

30분에서 1시간 소요된다.

`unsafe_show_logs=true`는 `no_log`가 걸린 태스크의 출력을 표시한다.
etcd 인증서 관련 태스크가 여기 해당하며, 실패 시 원인 파악에 필수다.

세션 유지가 불안하면 `tmux`를 사용한다.

```bash
tmux new -s kubespray
# Ctrl+B, D 로 분리 / tmux attach -t kubespray 로 복귀
```

**`--limit` 옵션은 사용하지 않는다.** 그룹 변수 평가가 제한되어
etcd 인증서 생성이 누락될 수 있다.
([troubleshooting/01](troubleshooting/01-etcd-worker-certs.md))

### 8. 실행 후 필수 작업

**`/opt/cni/bin` 소유자를 root로 변경한다.**

Kubespray는 이 디렉터리를 `kube:root`로 설정하나, Cilium의 `mount-cgroup`
init 컨테이너가 `DAC_OVERRIDE` 없이 root로 실행되어 파일 쓰기가 거부된다.

**`cluster.yml`을 실행할 때마다 되돌아가므로 매번 수행해야 한다.**

```bash
ansible -i inventory/logssey/inventory.ini k8s_cluster -m shell -b \
  -a "chown root:root /opt/cni/bin && ls -ld /opt/cni/bin"

kubectl -n kube-system delete pods -l k8s-app=cilium
```

상세는 [troubleshooting/03](troubleshooting/03-cilium-cni-bin-permission.md) 참조.

---

## 검증

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config

kubectl get nodes -o wide
kubectl get pods -A
```

| 확인 | 기대 |
| --- | --- |
| 노드 | CP 3 + Worker 3 = **6대** Ready |
| CoreDNS | 2개 Running (1/1) |
| cilium | DaemonSet 전 노드 Running |
| hubble-relay | Running (1/1) |
| kube-proxy | **없음** (replacement 사용) |

**etcd 전용 노드는 `kubectl get nodes`에 나타나지 않는다.**
Kubernetes 노드가 아니라 etcd 프로세스만 실행하기 때문이다.

### Cilium

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status \
  | grep -E "KubeProxyReplacement|Routing|Cluster health|IPAM"
```

| 항목 | 기대값 |
| --- | --- |
| KubeProxyReplacement | `True` |
| Routing | `Network: Tunnel [vxlan]` |
| Cluster health | `6/6 reachable` |
| IPAM | `10.244.x.0/24` |

eBPF 로드밸런서 등록 확인.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list | grep "10.96.0.1"
```

Control Plane 3대가 백엔드로 등록되어야 한다.

`kubectl exec`가 무한 대기하면 노드에서 직접 실행한다.

```bash
CID=$(sudo crictl ps --name cilium-agent -q | head -1)
sudo crictl exec $CID cilium-dbg status --brief
```

### DNS

```bash
kubectl run nettest --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c "nslookup kubernetes.default.svc.cluster.local; nslookup google.com"
```

내부 Service 해석과 외부 도메인 해석이 모두 성공해야 한다.
외부 해석은 NAT Gateway 경로까지 검증한다.

### etcd

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "/usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/ssl/etcd/ssl/ca.pem \
      --cert=/etc/ssl/etcd/ssl/admin-etcd-a.pem \
      --key=/etc/ssl/etcd/ssl/admin-etcd-a-key.pem \
      endpoint health --cluster"
```

3개 엔드포인트 전부 `is healthy` 여야 한다.

### NLB 타겟 상태

`cluster.yml` 완료 후 Internal API NLB 타겟이 healthy로 전환된다.
헬스체크 간격 10초, 임계 3회이므로 30초 내에 반영된다.

```bash
aws elbv2 describe-target-health \
  --target-group-arn <API_TG_ARN> \
  --region ap-northeast-1 \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' \
  --output table
```

---

## 구축 중 발생한 이슈

5건 발생했다. 상세는 [troubleshooting](troubleshooting/) 참조.

| # | 문제 | 원인 |
| --- | --- | --- |
| [01](troubleshooting/01-etcd-worker-certs.md) | 워커 etcd 인증서 미생성 | Kubespray `gen_certs` 평가 순서 |
| [02](troubleshooting/02-etcd-client-sg.md) | etcd 헬스체크 실패 | SG — 멤버 간 2379 누락 |
| [03](troubleshooting/03-cilium-cni-bin-permission.md) | Cilium mount-cgroup 실패 | `/opt/cni/bin` 소유자 |
| [04](troubleshooting/04-kube-proxy-ipvs-conflict.md) | Service 접속 불가 | kube-proxy IPVS ↔ eBPF 충돌 |
| [05](troubleshooting/05-apiserver-sg-kpr.md) | Service 접속 불가 (재발) | SG — Worker → CP 6443 누락 |

이 중 03은 `cluster.yml` 재실행마다 재현되므로 "실행 후 필수 작업"으로 절차화했다.

## 제거된 변수 (구버전 예제 주의)

| 변수 | 상태 |
| --- | --- |
| `etcd_kubeadm_enabled` | 제거됨. 인벤토리에 있으면 에러 |
| `gateway_api_experimental_channel` | deprecated → `gateway_api_channel` |
| `cilium_enable_bpf_clock_probe` | 제거됨 → `cilium_extra_values` |
| `kube_version: v1.x.x` | `v` 접두사 제거 |

## 실패 시 대응

`cluster.yml`이 중간에 실패하면 원인을 수정하고 재실행한다.
Kubespray는 멱등성을 가지므로 이미 완료된 단계는 건너뛴다.

| 증상 | 확인 |
| --- | --- |
| 특정 노드에서 멈춤 | SSH 키 배포, SG 22번 |
| etcd 인증서 태스크 실패 | 워커용 인증서 존재 여부 ([01](troubleshooting/01-etcd-worker-certs.md)) |
| etcd 헬스체크 실패 | SG 2379 멤버 간 ([02](troubleshooting/02-etcd-client-sg.md)) |
| 노드가 NotReady | Cilium Pod 상태, `/opt/cni/bin` 소유자 ([03](troubleshooting/03-cilium-cni-bin-permission.md)) |
| CoreDNS가 Ready 안 됨 | Service IP 접속 경로, SG 6443 ([05](troubleshooting/05-apiserver-sg-kpr.md)) |
| apiserver 간헐 타임아웃 | **NLB Client IP Preservation** |
| Pod가 IP를 못 받음 | Pod CIDR 충돌 |

로그에서 실패 지점을 찾는 방법.

```bash
grep -n "fatal:" /tmp/cluster.log | head
FIRST=$(grep -n "fatal:" /tmp/cluster.log | head -1 | cut -d: -f1)
sed -n "$((FIRST-25)),$((FIRST+35))p" /tmp/cluster.log
```

완전히 되돌리려면 `reset.yml`을 실행한다.

```bash
ansible-playbook -i inventory/logssey/inventory.ini reset.yml -b
```
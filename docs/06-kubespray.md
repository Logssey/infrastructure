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
```

**Pod/Service CIDR을 명시적으로 지정한다.**
Kubespray 기본값(`10.233.x`)은 VPC 대역(`10.20.0.0/16`)과 겹치지 않으나,
설계 문서의 값과 일치시켜 혼선을 방지한다.
클러스터 생성 후 변경은 사실상 재구축에 해당한다.

### group_vars/k8s_cluster/k8s-net-cilium.yml

```yaml
cilium_tunnel_mode: vxlan            # UDP 8472
cilium_kube_proxy_replacement: false # 1차 구축에서는 미적용

cilium_enable_hubble: true
cilium_enable_hubble_ui: false       # Relay 만 사용
```

**AWS 멀티 서브넷 환경에서는 캡슐화가 필수다.**
캡슐화 없는 라우팅 모드는 Pod 경로가 노드 커널 라우팅 테이블에만 등록되는데,
AWS VPC 라우터는 이를 인지하지 못해 Subnet이 다른 노드 간 통신이 드롭된다.

kube-proxy replacement를 적용하지 않아도 NetworkPolicy와 Hubble은
eBPF로 동작한다.

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
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

출력된 공개키를 복사한다.

### 2. SSH 공개키 배포 — SSM Run Command

로컬 터미널에서 나머지 8대에 한 번에 배포한다.
SSM Run Command는 인스턴스에 명령을 원격 실행하는 기능으로,
SSH 접속 없이 공개키를 등록할 수 있다.

```bash
# 대상 인스턴스 ID 수집 (cp-a 제외)
TARGETS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=logssey" \
            "Name=instance-state-name,Values=running" \
  --region ap-northeast-1 \
  --query "Reservations[].Instances[?Tags[?Key=='Name' && Value!='logssey-prod-cp-a'] && Tags[?Key=='Role' && Value!='redis']].InstanceId" \
  --output text)

echo $TARGETS
```

Redis 노드는 클러스터 구성원이 아니므로 제외한다. 8대가 나와야 한다.

```bash
PUBKEY='ssh-ed25519 AAAA... ubuntu@cp-a'   # 1단계에서 복사한 값

aws ssm send-command \
  --region ap-northeast-1 \
  --document-name "AWS-RunShellScript" \
  --targets "Key=instanceids,Values=$(echo $TARGETS | tr ' ' ',')" \
  --parameters "commands=[
    'mkdir -p /home/ubuntu/.ssh',
    'chmod 700 /home/ubuntu/.ssh',
    'grep -qxF \"$PUBKEY\" /home/ubuntu/.ssh/authorized_keys || echo \"$PUBKEY\" >> /home/ubuntu/.ssh/authorized_keys',
    'chmod 600 /home/ubuntu/.ssh/authorized_keys',
    'chown -R ubuntu:ubuntu /home/ubuntu/.ssh'
  ]" \
  --comment "Distribute kubespray SSH public key"
```

`grep -qxF ... ||` 조건으로 중복 등록을 방지한다. 재실행해도 안전하다.

실행 결과 확인.

```bash
CMD_ID=<위 출력의 CommandId>

aws ssm list-command-invocations \
  --command-id $CMD_ID \
  --region ap-northeast-1 \
  --query 'CommandInvocations[].[InstanceId,Status]' \
  --output table
```

8대 전부 `Success` 여야 한다.

### 3. Kubespray 클론 및 환경 구성

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

### 4. 인벤토리 작성

```bash
cp -r inventory/sample inventory/logssey
```

`inventory/logssey/inventory.ini` 및 `group_vars` 를 위 "주요 변수" 절대로 편집한다.

### 5. 소통 확인

```bash
ansible -i inventory/logssey/inventory.ini all -m ping
```

9대 전부 `SUCCESS` 여야 한다. 실패하면 SSH 키 배포 또는 SG 22번 규칙을 확인한다.

### 6. 클러스터 구축

```bash
tmux new -s kubespray
source .venv/bin/activate
ansible-playbook -i inventory/logssey/inventory.ini cluster.yml -b -v
```

30분에서 1시간 소요된다. `tmux`로 실행해 세션이 끊겨도 진행되도록 한다.
세션 복귀는 `tmux attach -t kubespray`.

---

## 검증

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

kubectl get nodes -o wide
kubectl get pods -A
```

| 확인 | 기대 |
| --- | --- |
| 노드 | CP 3 + Worker 3 = **6대** Ready |
| CoreDNS | Running |
| cilium | DaemonSet 전 노드 Running |

**etcd 전용 노드는 `kubectl get nodes`에 나타나지 않는다.**
Kubernetes 노드가 아니라 etcd 프로세스만 실행하기 때문이다.

```bash
# Cilium 상태
kubectl -n kube-system exec ds/cilium -- cilium status

# etcd 클러스터 상태 (etcd 노드에서)
sudo etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-etcd-a.pem \
  --key=/etc/ssl/etcd/ssl/admin-etcd-a-key.pem \
  member list
```

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
| etcd 태스크 실패 | SG 2379/2380, 노드 간 시간 동기화 |
| 노드가 NotReady | CNI 설치 여부, VXLAN UDP 8472 |
| apiserver 간헐 타임아웃 | **NLB Client IP Preservation** |
| Pod가 IP를 못 받음 | Pod CIDR 충돌 |

완전히 되돌리려면 `reset.yml`을 실행한다.

```bash
ansible-playbook -i inventory/logssey/inventory.ini reset.yml -b
```

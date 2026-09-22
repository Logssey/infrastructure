# 01. 워커 노드 etcd 인증서 미생성

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-21 |
| 단계 | `cluster.yml` 실행 중 (etcd 역할) |
| 영향 | 워커 3대 실패, 플레이북 중단 → etcd 설치 이후 단계 진행 불가 |
| 환경 | Kubespray v2.31.0, External etcd, Cilium |

## 증상

`cluster.yml` 실행 시 워커 3대에서 동일한 태스크가 실패했다.

```
PLAY RECAP
cp-a      : ok=447 failed=0
etcd-a    : ok=100 failed=0
worker-a  : ok=413 failed=1
worker-c  : ok=413 failed=1
worker-d  : ok=413 failed=1
```

초기 실행에서는 `no_log` 때문에 내용이 가려져 있었다.

```
TASK [etcd : Gen_certs | Gather node certs]
fatal: [worker-a -> etcd-a(10.20.20.10)]: FAILED! =>
  {"censored": "the output has been hidden due to the fact that
   'no_log: true' was specified for this result"}
```

## 진단 과정

### 1. no_log 해제

Kubespray는 `unsafe_show_logs` 변수로 `no_log`를 제어한다.

```bash
ansible-playbook -i inventory/logssey/inventory.ini cluster.yml -b \
  -e unsafe_show_logs=true 2>&1 | tee /tmp/full.log
```

실제 에러가 드러났다.

```
cmd: "tar cfz - -C /etc/ssl/etcd/ssl ca.pem node-worker-c.pem node-worker-c-key.pem | base64 --wrap=0"
stderr: "tar: node-worker-c.pem: Cannot stat: No such file or directory"
```

### 2. 인증서 목록 확인

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "ls /etc/ssl/etcd/ssl/ | grep node-"
```

```
node-cp-a-key.pem
node-cp-a.pem
node-cp-c-key.pem
node-cp-c.pem
node-cp-d-key.pem
node-cp-d.pem
```

**Control Plane 3대 것만 있고 워커용이 없다.**

### 3. 생성 태스크 확인

`roles/etcd/tasks/gen_certs_script.yml`에 생성 태스크가 두 개 있다.

```yaml
- name: Gen_certs | run cert generation script for etcd and kube control plane nodes
  environment:
    HOSTS: "{{ groups['gen_node_certs_True'] | intersect(groups['kube_control_plane']) | join(' ') }}"
  run_once: true
  when: gen_certs | default(false)

- name: Gen_certs | run cert generation script for all clients
  environment:
    HOSTS: "{{ groups['gen_node_certs_True'] | intersect(groups['k8s_cluster']) | join(' ') }}"
  run_once: true
  when:
    - kube_network_plugin in ["calico", "flannel", "cilium"] or cilium_deploy_additionally
    - kube_network_plugin != "calico" or calico_datastore == "etcd"
    - gen_certs | default(false)
```

앞은 Control Plane만, 뒤는 `k8s_cluster`(CP + Worker) 전체를 대상으로 한다.

로그에서 실행 여부를 확인했다.

```bash
grep -n "run cert generation script" /tmp/full.log
```

```
5231:TASK [etcd : Gen_certs | run cert generation script for etcd and kube control plane nodes]
```

**두 번째 태스크가 실행되지 않았다.**

### 4. 조건 확인

`roles/etcd/tasks/check_certs.yml`에 `gen_certs`를 설정하는 태스크가 두 개 있다.

```bash
grep -n "gen_certs" /tmp/full.log
```

```
5081: Check_certs | Set default value for 'sync_certs', 'gen_certs' ... to false
5132: Check_certs | Set 'gen_certs' to true if expected certificates are not on the first etcd node(1/2)
```

`(2/2)`가 실행되지 않았다. 이 태스크가 `k8s_cluster` 전체의 인증서 존재 여부를 검사해
`gen_certs`를 설정하는데, `(1/2)`에서 이미 CP 인증서가 생성되면서
조건 평가가 어긋난 것으로 보인다.

두 태스크 모두 `run_once: true`라 play의 첫 호스트에서만 평가된다.

## 원인

Kubespray의 `gen_certs` 평가 순서 문제.
Control Plane 인증서 생성 후 `gen_certs` 상태가 변해 워커용 생성 태스크가 스킵된다.

`etcd_node_cert_hosts` 기본값은 `groups['k8s_cluster']`로 워커를 포함하고 있으므로
변수 설정 문제는 아니다.

```bash
grep -rn "etcd_node_cert_hosts" roles/
# roles/etcd_defaults/defaults/main.yml:70:etcd_node_cert_hosts: "{{ groups['k8s_cluster'] }}"
```

## 해결

etcd-a에서 인증서 생성 스크립트를 직접 실행한다. 스크립트는 이미 생성되어 있다.

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "ls -la /usr/local/bin/etcd-scripts/"
# make-ssl-etcd.sh
```

`HOSTS` 환경변수에 워커 노드를 지정해 실행한다.

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "HOSTS='worker-a worker-c worker-d' \
      bash -x /usr/local/bin/etcd-scripts/make-ssl-etcd.sh \
      -f /etc/ssl/etcd/openssl.conf -d /etc/ssl/etcd/ssl"
```

확인.

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "ls /etc/ssl/etcd/ssl/ | grep node-"
```

`node-worker-*` 6개가 추가되면 `cluster.yml`을 재실행한다.

## 재발 방지

`cluster.yml` 재실행 시 이미 인증서가 존재하므로 재발하지 않는다.
다만 **인증서를 전부 삭제하고 처음부터 다시 만들 경우 재현될 수 있다.**

노드를 추가할 때(`scale.yml`) 같은 문제가 발생하면 동일하게 수동 생성한다.

## 참고

| 항목 | 경로 |
| --- | --- |
| 생성 태스크 | `roles/etcd/tasks/gen_certs_script.yml` |
| 조건 판단 | `roles/etcd/tasks/check_certs.yml` |
| 변수 기본값 | `roles/etcd_defaults/defaults/main.yml` |
| 생성 스크립트 | 노드의 `/usr/local/bin/etcd-scripts/make-ssl-etcd.sh` |

`no_log`가 걸린 태스크는 `-e unsafe_show_logs=true`로 출력을 볼 수 있다.
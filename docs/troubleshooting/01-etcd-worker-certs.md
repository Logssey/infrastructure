# 01. 워커 노드 etcd 인증서 미생성

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-21 |
| 단계 | `cluster.yml` 실행 중 (etcd 역할) |
| 영향 | 워커 3대 실패, 플레이북 중단 → etcd 설치 이후 단계 진행 불가 |
| 환경 | Kubespray v2.31.0, External etcd, Cilium |

## 배경 — etcd 인증서 3종

Kubespray 는 용도별로 세 종류의 인증서를 생성한다.

| 접두사 | 용도 | 배포 대상 |
| --- | --- | --- |
| `member-` | etcd 서버·peer 통신 | etcd 노드 |
| `admin-` | etcdctl 클라이언트 | etcd 노드 |
| `node-` | etcd 클라이언트 | Control Plane, Worker |

파일명은 **인벤토리 호스트명**을 따른다. etcd 내부 멤버명(`etcd1`)과 다르다.

```
member-etcd-a.pem     etcd-a 의 서버 인증서
node-worker-a.pem     worker-a 의 etcd 클라이언트 인증서
```

`node-` 인증서는 CNI 가 etcd 를 데이터 저장소로 사용할 때 필요하다.
본 환경의 Cilium 은 CRD 모드로 동작하므로 **실제로는 사용되지 않는다.**

```bash
ansible -i inventory/logssey/inventory.ini worker-a -m shell -b \
  -a "grep -rl 'node-worker-a' /etc/ 2>/dev/null"
# 출력 없음
```

배포는 되지만 참조하는 설정 파일이 없다.
Kubespray 가 `kube_network_plugin` 이 cilium 이면 무조건 생성하는 구조다.

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

### 4. gen_certs 평가 확인

`roles/etcd/tasks/check_certs.yml`에 `gen_certs`를 설정하는 태스크가 두 개 있다.

```bash
grep -n "gen_certs" /tmp/full.log
```

```
5081: Check_certs | Set default value for 'sync_certs', 'gen_certs' ... to false
5132: Check_certs | Set 'gen_certs' to true if expected certificates are not on the first etcd node(1/2)
```

`(2/2)`가 실행되지 않았다.

## 원인

두 태스크는 **검사 대상 호스트 그룹이 다르다.**

```jinja
(1/2)  {% set k8s_nodes = groups['kube_control_plane'] %}
(2/2)  {% set k8s_nodes = groups['k8s_cluster'] | unique | sort %}
```

`(1/2)` 는 Control Plane 의 `node-` 인증서만, `(2/2)` 는 Worker 까지 포함해 검사한다.

두 태스크 모두 같은 조건으로 `gen_certs` 를 설정한다.

```yaml
when:
  - ...
  - force_etcd_cert_refresh or not item in etcdcert_master.files | map(attribute='path') | list
```

`etcdcert_master` 는 태스크 파일 **맨 위에서 한 번만** 수집된다.

```yaml
- name: "Check_certs | Register certs that have already been generated on first etcd node"
  find:
    paths: "{{ etcd_cert_dir }}"
    patterns: "ca.pem,node*.pem,member*.pem,admin*.pem"
  register: etcdcert_master
  run_once: true
```

`check_certs.yml` 은 `cluster.yml` 실행 중 여러 번 호출된다.
2회차 이후에는 `(1/2)` 가 검사하는 CP 인증서가 이미 존재하므로 조건이 거짓이 되고,
`gen_certs` 는 기본값 `false` 로 남는다.

`(2/2)` 가 Worker 인증서 부재를 감지해 `true` 로 덮어써야 하나,
같은 `etcdcert_master` 스냅샷을 참조하는 평가 시점 문제로 실행되지 않았다.

`etcd_node_cert_hosts` 기본값은 `groups['k8s_cluster']` 로 워커를 포함하므로
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

`no_log`가 걸린 태스크는 `-e unsafe_show_logs=true`로 출력을 볼 수 있다.
etcd 인증서 관련 태스크 대부분이 여기 해당하므로 처음부터 켜고 실행하는 것이 낫다.

## 참고

| 항목 | 경로 |
| --- | --- |
| 생성 태스크 | `roles/etcd/tasks/gen_certs_script.yml` |
| 조건 판단 | `roles/etcd/tasks/check_certs.yml` |
| 변수 기본값 | `roles/etcd_defaults/defaults/main.yml` |
| 생성 스크립트 | 노드의 `/usr/local/bin/etcd-scripts/make-ssl-etcd.sh` |
# 03. Cilium mount-cgroup init 컨테이너 실패

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-21 |
| 단계 | `cluster.yml` 완료 후 (Cilium Pod 기동) |
| 영향 | 전 노드 NotReady, CNI 미동작 → 모든 Pod 스케줄 불가 |
| 환경 | Kubespray v2.31.0, Cilium 1.19.3, Ubuntu 24.04 (커널 7.0.0-1012-aws) |

## 증상

`cluster.yml` 은 `failed=0` 으로 완료했으나 노드가 Ready 가 되지 않았다.

```
NAME       STATUS     ROLES           AGE   VERSION
cp-a       NotReady   control-plane   9m    v1.35.4
cp-c       NotReady   control-plane   8m    v1.35.4
worker-a   NotReady   <none>          7m    v1.35.4
```

Cilium agent Pod 가 전부 init 단계에서 재시작을 반복했다.

```
cilium-mpbqr       0/1   Init:CrashLoopBackOff   6 (2m3s ago)   7m38s
cilium-envoy-*     1/1   Running                 0              7m38s
cilium-operator-*  1/1   Running                 0              7m38s
coredns-*          0/1   Pending                 0              2m11s
```

**agent 만 죽고 envoy 와 operator 는 정상**이라는 점이 단서였다.

## 진단 과정

### 1. 어느 init 컨테이너인지 확인

Cilium agent 는 init 컨테이너가 6개다.

```bash
kubectl -n kube-system get pod cilium-mpbqr \
  -o jsonpath='{.spec.initContainers[*].name}'
```

```
config mount-cgroup apply-sysctl-overwrites mount-bpf-fs clean-cilium-state install-cni-binaries
```

Events 에서 반복 실패 대상을 확인했다.

```bash
kubectl -n kube-system describe pod cilium-mpbqr | tail -40
```

```
Normal   Started  3m21s (x7 over 8m53s)  kubelet  spec.initContainers{mount-cgroup}: Container started
Warning  BackOff  65s (x12 over 8m51s)   kubelet  spec.initContainers{mount-cgroup}: Back-off restarting failed container
```

`config` 는 Exit 0 으로 완료했고 **`mount-cgroup` 에서 멈춰 있다.**

### 2. 로그가 비어 있음

```bash
kubectl -n kube-system logs cilium-mpbqr -c mount-cgroup --tail=30
# (출력 없음)
```

컨테이너가 출력 없이 종료했다. 종료 상태를 직접 조회해야 했다.

```bash
kubectl -n kube-system get pod cilium-mpbqr \
  -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{"\t"}{.lastState}{"\n"}{end}'
```

```json
mount-cgroup {"terminated":{
  "exitCode":1,
  "message":"cp: cannot create regular file '/hostbin/cilium-mount': Permission denied\n",
  "reason":"Error"}}
```

**에러 메시지 확보.** `/hostbin` 에 파일을 쓰지 못한다.

### 3. 실행 명령과 마운트 확인

```bash
kubectl -n kube-system describe pod cilium-mpbqr | grep -A20 "mount-cgroup:"
```

```
Command:
  bash
  -ec
  cp /usr/bin/cilium-mount /hostbin/cilium-mount;
  nsenter --cgroup=/hostproc/1/ns/cgroup --mount=/hostproc/1/ns/mnt "${BIN_PATH}/cilium-mount" $CGROUP_ROOT;
  rm /hostbin/cilium-mount
```

`/hostbin` 이 어느 호스트 경로인지 확인했다.

```bash
kubectl -n kube-system get pod cilium-mpbqr \
  -o jsonpath='{range .spec.volumes[*]}{.name}{"\t"}{.hostPath.path}{"\n"}{end}'
```

```
cni-path    /opt/cni/bin
```

마운트가 읽기 전용인지도 확인했다.

```bash
kubectl -n kube-system get pod cilium-mpbqr \
  -o jsonpath='{.spec.initContainers[1].volumeMounts}' | python3 -m json.tool
```

```json
[
  {"mountPath": "/hostproc", "name": "hostproc"},
  {"mountPath": "/hostbin", "name": "cni-path"}
]
```

`readOnly` 가 아니다. 마운트 옵션 문제는 아니었다.

### 4. AppArmor 의심 — 오판

Ubuntu 24.04 는 AppArmor 가 기본 활성이고 `cri-containerd.apparmor.d` 프로파일이
enforce 모드였다.

```bash
sudo aa-status | head -20
```

```
27 profiles are in enforce mode.
   cri-containerd.apparmor.d
```

Pod 에 unconfined 어노테이션을 추가해 보았다.

```bash
kubectl -n kube-system patch ds cilium --type merge -p '
{"spec":{"template":{"metadata":{"annotations":{
  "container.apparmor.security.beta.kubernetes.io/mount-cgroup": "unconfined"
}}}}}'
```

어노테이션은 적용되었으나 **증상이 그대로였다.**

```bash
kubectl -n kube-system get pod $POD -o jsonpath='{.spec.securityContext}' | python3 -m json.tool
```

```json
{
  "appArmorProfile": {"type": "Unconfined"},
  "seccompProfile": {"type": "Unconfined"}
}
```

`dmesg` 에도 Cilium 관련 `apparmor="DENIED"` 항목이 없었다. AppArmor 는 원인이 아니었다.

### 5. 호스트에서 쓰기 테스트

```bash
sudo touch /opt/cni/bin/testfile && echo "쓰기 가능"
# 쓰기 가능
```

호스트의 root 는 쓸 수 있다. 컨테이너에서만 거부된다.

### 6. capability 확인 — 원인 발견

```bash
kubectl -n kube-system get pod $POD \
  -o jsonpath='{.spec.initContainers[1].securityContext}' | python3 -m json.tool
```

```json
{
  "capabilities": {
    "add": ["SYS_ADMIN", "SYS_CHROOT", "SYS_PTRACE"],
    "drop": ["ALL"]
  },
  "seLinuxOptions": {"level": "s0", "type": "spc_t"}
}
```

**`drop: ["ALL"]` 후 3개만 추가했고 `DAC_OVERRIDE` 가 없다.**

디렉터리 권한을 확인했다.

```bash
ls -ld /opt/cni/bin
```

```
drwxr-xr-x 2 kube root 4096 /opt/cni/bin
```

소유자가 `kube`, 권한 `755`. 그룹과 기타 사용자는 쓰기 권한이 없다.

## 원인

`DAC_OVERRIDE` capability 는 **파일 권한 검사를 우회**하는 권한이다.
일반적으로 root(UID 0)가 모든 파일에 접근할 수 있는 이유가 이 capability 때문이다.

Cilium 의 `mount-cgroup` 컨테이너는 root 로 실행되지만
`drop: ALL` 로 `DAC_OVERRIDE` 를 버렸기 때문에 **일반 파일 권한 규칙을 그대로 따른다.**

```
/opt/cni/bin  →  kube:root 755
                 소유자(kube)만 쓰기 가능
                 root 라도 DAC_OVERRIDE 없으면 거부
```

호스트에서 `sudo touch` 가 성공했던 것은 그 root 가 모든 capability 를 갖고 있었기 때문이다.

Kubespray 는 Kubernetes 관련 디렉터리를 `kube` 사용자 소유로 설정하는데,
Cilium 은 root 소유를 전제로 동작한다. 두 전제가 어긋났다.

## 해결

디렉터리 소유자를 root 로 변경한다.

```bash
ansible -i inventory/logssey/inventory.ini k8s_cluster -m shell -b \
  -a "chown root:root /opt/cni/bin && ls -ld /opt/cni/bin"
```

Cilium Pod 를 재시작한다.

```bash
kubectl -n kube-system delete pods -l k8s-app=cilium
```

30초 내에 전부 Running 으로 전환되고 노드가 Ready 가 된다.

```
cilium-7smk5   1/1   Running   0   34s
...
NAME       STATUS   ROLES           AGE
cp-a       Ready    control-plane   19m
worker-a   Ready    <none>          18m
```

`chmod 777 /opt/cni/bin` 으로도 해결되지만 소유자 변경이 더 적절하다.

## 재발 방지

**`cluster.yml` 을 실행할 때마다 소유자가 `kube:root` 로 되돌아간다.**
실제로 재실행 후 같은 증상이 재현되었다.

```
drwxr-xr-x 2 kube root 4096 Sep 21 12:12 /opt/cni/bin
```

따라서 Kubespray 실행 후 매번 chown 을 수행해야 한다.
이 절차를 `kubespray/README.md` 의 "실행 후 필수 작업" 에 기록했다.

```bash
ansible -i inventory/logssey/inventory.ini k8s_cluster -m shell -b \
  -a "chown root:root /opt/cni/bin"

kubectl -n kube-system delete pods -l k8s-app=cilium
```

노드를 신규 생성할 경우 Terraform `user_data` 에 포함하는 방법도 있으나,
Kubespray 가 이후 덮어쓰므로 근본 해결은 되지 않는다.

## 교훈

**`drop: ALL` 은 root 라도 파일 권한 규칙을 따르게 만든다.**

컨테이너가 root 로 실행된다고 해서 모든 파일에 접근할 수 있는 것은 아니다.
`Permission denied` 가 나오면 capability 설정을 함께 확인해야 한다.

init 컨테이너가 출력 없이 종료하면 로그가 비어 있다.
이때는 `.status.initContainerStatuses[*].lastState` 에서 종료 메시지를 확인한다.

```bash
kubectl -n <ns> get pod <pod> \
  -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{"\t"}{.lastState.terminated.message}{"\n"}{end}'
```

AppArmor 를 의심했으나 오판이었다. `dmesg | grep apparmor` 에
해당 프로세스의 `DENIED` 항목이 없으면 AppArmor 는 원인이 아니다.

## 참고

| 항목 | 내용 |
| --- | --- |
| 실패 컨테이너 | `mount-cgroup` (Cilium agent init 2번째) |
| 대상 경로 | `/opt/cni/bin` (컨테이너 내 `/hostbin`) |
| 누락 capability | `DAC_OVERRIDE` |
| 조치 절차 | `kubespray/README.md` |
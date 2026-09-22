# 07. L7 NetworkPolicy 미동작 — iptables 재조정 실패

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-22 |
| 단계 | `cilium connectivity test` |
| 영향 | L7 정책 전면 미동작. 기본 통신은 정상이라 연결 당시 드러나지 않았음 |
| 환경 | Kubespray v2.31.0, Cilium 1.19.3 |

## 증상

`cilium connectivity test` 결과 79개 중 24개가 실패했다.

```
❌ 24/79 tests failed (101/775 actions), 47 tests skipped
```

실패 항목이 한 부류에 몰려 있었다.

| 분류 | 개수 |
| --- | --- |
| L7 정책 (ingress / egress / TLS SNI) | 약 17 |
| `check-log-errors` | 6 |
| `pod-to-hostport` | 1 |

`no-policies` 기본 테스트는 대부분 통과했다.
Pod 간 통신, Service 접근, DNS 모두 정상이라는 뜻이다.

결정적인 단서는 `client-egress-l7/pod-to-pod` 였다.
**같은 Pod 간 통신인데 L7 정책을 적용하면 실패**하고, 정책 없이는 성공했다.

```
🟥 client-egress-l7/pod-to-pod:curl-ipv4-2:
   client2 (10.244.1.39) -> echo-other-node (10.244.0.186:8080):
   exit code 28 (timeout)
```

## 진단 과정

### 1. Cilium agent 로그

전 노드에서 같은 에러가 10초 간격으로 반복되고 있었다.

```bash
kubectl -n kube-system logs ds/cilium --tail=5
```

```
level=error msg="iptables rules full reconciliation failed, will retry another one later"
module=agent.datapath.iptables
error="failed to remove old backup rules: unable to run
  'iptables -t nat -D OLD_CILIUM_POST_nat -s 10.244.3.0/24 ! -d 99.105.108.105/24
   ! -o cilium_+ -m comment --comment cilium masquerade non-cluster -j MASQUERADE'
  iptables command: exit status 1
  stderr=\"iptables: Bad rule (does a matching rule exist in that chain?).\""
```

`4274 occurrences` — 10초 간격이므로 약 12시간 누적이다.

### 2. Cilium 의 iptables 관리 방식 확인

Cilium 은 규칙을 교체할 때 기존 체인을 `OLD_` 접두사로 rename 해 백업하고,
새 규칙이 성공적으로 추가된 뒤 백업을 제거한다.
교체 중에도 기존 규칙이 유효해 패킷이 끊기지 않도록 하는 설계다.

reconciler 는 실패 시 `stateChanged` 를 `true` 로 유지하고 다음 주기에 재시도한다.

```go
if err := updateRules(state, firstInit); err != nil {
    log.WithError(err).Error("iptables rules full reconciliation failed, will retry another one later")
    health.Degraded("iptables rules full reconciliation failed", err)
    // Keep stateChanged=true to try again on the next tick.
}
```

**백업 제거가 실패하면 재조정 전체가 완료되지 않는다.**
L7 정책에 필요한 프록시 리다이렉트 규칙도 이 재조정으로 적용되므로 함께 막힌다.

### 3. OLD_ 체인 확인

```bash
ansible -i inventory/logssey/inventory.ini k8s_cluster -m shell -b \
  -a "iptables-save -t nat | grep -c '^:OLD_CILIUM'"
```

6대 전부 3개씩 존재했다.

```bash
ansible -i inventory/logssey/inventory.ini worker-a -m shell -b \
  -a "iptables-save -t nat | grep OLD_CILIUM"
```

```
:OLD_CILIUM_OUTPUT_nat - [0:0]
:OLD_CILIUM_POST_nat - [0:0]
:OLD_CILIUM_PRE_nat - [0:0]
-A OLD_CILIUM_POST_nat -s 10.244.0.0/24 ! -d 10.244.0.0/24 ! -o cilium_+ -m comment --comment "cilium masquerade non-cluster" -j MASQUERADE
-A OLD_CILIUM_POST_nat -m mark --mark 0xa00/0xe00 -m comment --comment "exclude proxy return traffic from masquerade" -j ACCEPT
...
```

### 4. 삭제 명령과 실제 규칙 비교

```
Cilium 시도:  -s 10.244.0.0/24 ! -d 99.105.108.105/24 ! -o cilium_+ ...
실제 규칙:    -s 10.244.0.0/24 ! -d 10.244.0.0/24     ! -o cilium_+ ...
```

`-s` 는 일치하고 **`-d` 만 `99.105.108.105/24`** 라는 값으로 어긋나 있다.
이 주소는 VPC(10.20.0.0/16), Pod(10.244.0.0/16), Service(10.96.0.0/16)
어디에도 속하지 않는다.

ConfigMap 에는 해당 값이 없었다.

```bash
kubectl -n kube-system get cm cilium-config -o yaml | grep -iE "native-routing-cidr|masquerade"
```

```
enable-bpf-masquerade: "false"
enable-ipv4-masquerade: "true"
enable-ipv6-masquerade: "true"
```

`ipv4-native-routing-cidr` 자체가 정의되어 있지 않다.
Cilium 내부 상태가 손상된 것으로 판단했다.

### 5. 체인 수동 삭제 시도 — 실패

다른 체인에서 `OLD_` 를 참조하지 않는 것을 먼저 확인했다.

```bash
ansible -i inventory/logssey/inventory.ini worker-a -m shell -b \
  -a "iptables-save -t nat | grep -- '-j OLD_CILIUM'"
# rc=1 (미발견)
```

고아 체인이므로 삭제했다.

```bash
ansible -i inventory/logssey/inventory.ini worker-a -m shell -b -a "
iptables -t nat -F OLD_CILIUM_PRE_nat && iptables -t nat -X OLD_CILIUM_PRE_nat
iptables -t nat -F OLD_CILIUM_OUTPUT_nat && iptables -t nat -X OLD_CILIUM_OUTPUT_nat
iptables -t nat -F OLD_CILIUM_POST_nat && iptables -t nat -X OLD_CILIUM_POST_nat
"
```

**곧바로 재생성되었다.** 다음 재조정 주기에 Cilium 이 현재 체인을 다시
`OLD_` 로 rename 했고, 에러도 동일하게 계속되었다.

메모리 상태가 손상되어 있으므로 iptables 조작만으로는 해결되지 않는다.

## 원인

전날 kube-proxy 를 제거하면서 실행한 명령이 원인으로 판단된다.

```bash
iptables-save | grep -v KUBE- | iptables-restore
```

`KUBE-` 규칙만 제외한 뒤 **테이블 전체를 다시 적재**하는 방식이다.
이 과정에서 Cilium 규칙의 참조 관계가 어긋났고,
Cilium 이 내부에 기록해둔 규칙 정보와 실제 iptables 상태가 불일치하게 되었다.

Cilium 은 자신이 기록한 정보(`99.105.108.105/24` 가 포함된 규칙)를 삭제하려 하지만
실제로는 존재하지 않아 매번 실패한다.

## 해결

노드 재부팅. iptables 는 메모리에만 존재하므로 재부팅 시 초기화되고
Cilium 이 처음부터 규칙을 구성한다.

Control Plane 3대, Worker 3대이므로 **한 대씩 순차 진행**하면 서비스 중단이 없다.

```bash
# 1. drain
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force --timeout=120s

# 2. 재부팅 (로컬에서)
aws ec2 reboot-instances --instance-ids <id> --region ap-northeast-1

# 3. 복귀 확인 (2~3분 후)
kubectl get nodes
ansible -i inventory/logssey/inventory.ini <node> -m shell -b \
  -a "iptables-save -t nat | grep -c OLD_CILIUM"     # 0
ansible -i inventory/logssey/inventory.ini <node> -m shell -b -a "uptime"

POD=$(kubectl -n kube-system get pods -l k8s-app=cilium \
  --field-selector spec.nodeName=<node> -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec $POD -- cilium-dbg status --brief    # OK
kubectl -n kube-system logs $POD --since=30s | grep -c "reconciliation failed"   # 0

# 4. 복귀
kubectl uncordon <node>
```

순서는 Worker → Control Plane 이고, **Ansible 실행 노드(cp-a)를 마지막**에 한다.
재부팅 시 SSM 세션이 끊기므로 drain 후 세션을 종료하고 로컬에서 재부팅한다.

### 재부팅 중 확인한 것

Control Plane 재부팅 시 Internal NLB 가 해당 노드를 자동 제외했다.

```
|  i-0cce08c8ec9f4598d |  unhealthy  |    ← 재부팅 중인 cp-c
|  i-0dbf490c1a48989c3 |  healthy    |
|  i-08698ab3a5415d8fb |  healthy    |
```

복귀 후 다시 `healthy` 로 전환되었다.
헬스체크 간격 10초, 임계 3회 설정이 의도대로 동작했다.

`/opt/cni/bin` 소유자(`root:root`)는 디스크에 저장되므로 재부팅 후에도 유지되었다.

## 결과

재부팅 완료 후 `cilium connectivity test` 를 재실행했다.
cilium CLI 도 v0.18.9 에서 v0.20.0 으로 함께 업그레이드했다.

| 항목 | 이전 | 이후 |
| --- | --- | --- |
| 테스트 수 | 79 | 80 |
| 실패 | 24 | **2** |
| L7 정책 | 전부 실패 | **전부 통과** |

남은 2건.

| 실패 | 판단 |
| --- | --- |
| `pod-to-hostport` | SG 에 hostPort 4000 없음. 사용하지 않는 기능이므로 의도된 실패 |
| `check-log-errors` | 재부팅 이전 로그와 restart count 1 을 검출. 시간 경과로 해소 |

## 재발 방지

**iptables 를 직접 조작하지 않는다.**

Cilium 이 관리하는 규칙은 Cilium 이 정리하게 두어야 한다.
kube-proxy 규칙을 제거할 필요가 있다면 `iptables-restore` 로 테이블을 통째로
다시 적재하는 대신, 노드를 재부팅하거나 kube-proxy 자체의 정리 기능을 사용한다.

```bash
# 사용하지 않는다
iptables-save | grep -v KUBE- | iptables-restore
```

증상이 즉시 나타나지 않는다는 점도 문제였다.
기본 통신은 정상이었기에 12시간 동안 인지하지 못했고,
`connectivity test` 를 실행하고 나서야 드러났다.

**구성 변경 후에는 `connectivity test` 로 검증한다.**

## 참고

| 항목 | 내용 |
| --- | --- |
| 원인 명령 | `docs/troubleshooting/04-kube-proxy-ipvs-conflict.md` 의 iptables 정리 단계 |
| Cilium reconciler | `pkg/datapath/iptables/reconciler.go` |
| 백업 체인 설계 | cilium/cilium PR #16745 |
| 진단 명령 모음 | `docs/troubleshooting/README.md` |
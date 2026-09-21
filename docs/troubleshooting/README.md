# 트러블슈팅

클러스터 구축 중 발생한 문제와 해결 과정. 결론뿐 아니라 **진단 과정**을 기록한다.

## 목록

| # | 제목 | 원인 | 단계 |
| --- | --- | --- | --- |
| [01](01-etcd-worker-certs.md) | 워커 노드 etcd 인증서 미생성 | Kubespray `gen_certs` 평가 순서 | cluster.yml |
| [02](02-etcd-client-sg.md) | etcd 클러스터 헬스체크 실패 | SG — etcd 멤버 간 2379 누락 | cluster.yml |
| [03](03-cilium-cni-bin-permission.md) | Cilium mount-cgroup 실패 | `/opt/cni/bin` 소유자, `DAC_OVERRIDE` 없음 | Cilium 기동 |
| [04](04-kube-proxy-ipvs-conflict.md) | Service 접속 불가 (병행 구성) | kube-proxy IPVS ↔ Cilium eBPF 충돌 | 클러스터 기동 후 |
| [05](05-apiserver-sg-kpr.md) | Service 접속 불가 (replacement) | SG — Worker → CP 6443 누락 | kube-proxy replacement 전환 후 |

04와 05는 같은 증상의 서로 다른 원인이다. 04를 해결한 뒤에도 증상이 남아 05로 이어졌다.

## 분류

| 유형 | 건수 | 해당 |
| --- | --- | --- |
| Security Group 설계 누락 | 3 | 02, 05(2건) |
| Kubespray 동작 특성 | 2 | 01, 04 |
| 환경 전제 불일치 | 1 | 03 |

**SG 관련이 절반이다.** 설계 시 정의한 통신 경로가 실제 도구의 동작과 달랐던 경우다.

## 설계 변경으로 이어진 항목

| 항목 | 당초 | 변경 |
| --- | --- | --- |
| kube-proxy replacement | 미적용 | 적용 |
| etcd 2379 접근 | Control Plane만 | + 멤버 간 |
| apiserver 접근 경로 | Internal NLB 경유 | + Worker → CP 직접 |
| 노드 간 ICMP | 미허용 | 허용 |

## 진단 참고

### 포트 차단 판별

```bash
timeout 3 bash -c 'echo > /dev/tcp/<IP>/<PORT>'; echo exit=$?
```

| 결과 | 의미 |
| --- | --- |
| `exit=0` | 정상 연결 |
| `Connection refused` (exit=1) | 포트 도달, 프로세스 없음 |
| `exit=124` | timeout — 방화벽 차단 |

### Ansible no_log 해제

```bash
ansible-playbook -i <inventory> cluster.yml -b -e unsafe_show_logs=true 2>&1 | tee /tmp/full.log
```

```bash
grep -n "fatal:" /tmp/full.log | head
FIRST=$(grep -n "fatal:" /tmp/full.log | head -1 | cut -d: -f1)
sed -n "$((FIRST-25)),$((FIRST+35))p" /tmp/full.log
```

### init 컨테이너 종료 메시지

로그가 비어 있을 때 사용한다.

```bash
kubectl -n <ns> get pod <pod> \
  -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{"\t"}{.lastState.terminated.message}{"\n"}{end}'
```

### kubectl exec 우회

`kubectl exec` 가 무한 대기하면 apiserver → kubelet 경로에 문제가 있다.
노드에서 직접 실행한다.

```bash
CID=$(sudo crictl ps --name cilium-agent -q | head -1)
sudo crictl exec $CID cilium-dbg status --brief
```

Ansible 로 전 노드에 적용할 수도 있다.

```bash
ansible -i <inventory> <host> -m shell -b \
  -a "CID=\$(crictl ps --name cilium-agent -q | head -1); crictl exec \$CID cilium-dbg status"
```

### 네트워크 진단 순서

위에서부터 좁혀간다. Service IP 부터 테스트하면 어느 계층이 문제인지 알 수 없다.

| 순서 | 확인 | 방법 |
| --- | --- | --- |
| 1 | Pod IP·라우팅 | `ip addr`, `ip route` |
| 2 | L3 경로 | `ping <노드 IP>` |
| 3 | 방화벽 | `/dev/tcp/<IP>/<PORT>` |
| 4 | Service 변환 | `cilium-dbg service list`, `bpf lb list` |
| 5 | Service 접속 | `wget https://10.96.0.1:443/healthz` |

**ICMP 가 SG에서 막힌 환경에서는 2번이 항상 실패**하므로 주의한다.
SSH·Ansible 이 동작하는데 ping 이 전부 실패하면 ICMP 차단을 의심한다.

## 작성 형식

새 문서는 아래 구조를 따른다.

```
# NN. 제목

| 발생 | 단계 | 영향 | 환경 |

## 증상          실제 에러 메시지와 상태
## 진단 과정      단계별 명령어와 출력
## 원인          왜 발생했는지
## 해결          실제 조치
## 재발 방지      설정 변경 / 절차 추가
## 교훈          일반화할 수 있는 내용
## 참고          관련 파일 경로
```

**오판한 과정도 남긴다.** 
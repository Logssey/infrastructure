# 트러블슈팅

클러스터 구축과 서비스 배포 중 발생한 문제와 해결 과정.
결론뿐 아니라 **진단 과정**을 기록한다.

## 목록

| # | 제목 | 원인 | 단계 |
| --- | --- | --- | --- |
| [01](01-etcd-worker-certs.md) | 워커 노드 etcd 인증서 미생성 | Kubespray `gen_certs` 평가 순서 | cluster.yml |
| [02](02-etcd-client-sg.md) | etcd 클러스터 헬스체크 실패 | SG — etcd 멤버 간 2379 누락 | cluster.yml |
| [03](03-cilium-cni-bin-permission.md) | Cilium mount-cgroup 실패 | `/opt/cni/bin` 소유자, `DAC_OVERRIDE` 없음 | Cilium 기동 |
| [04](04-kube-proxy-ipvs-conflict.md) | Service 접속 불가 (병행 구성) | kube-proxy IPVS ↔ Cilium eBPF 충돌 | 클러스터 기동 후 |
| [05](05-apiserver-sg-kpr.md) | Service 접속 불가 (replacement) | SG — Worker → CP 6443 누락 | kube-proxy replacement 전환 후 |
| [06](06-kubelet-api-sg.md) | kubelet API 접근 불가 | SG — 10250 방향 누락 | connectivity test |
| [07](07-iptables-corruption-l7.md) | L7 NetworkPolicy 미동작 | iptables 직접 조작으로 Cilium 상태 손상 | connectivity test |
| [08](08-envoy-gateway-nodeport.md) | Envoy Gateway NodePort 고정 실패 | StrategicMerge 병합 키, DoNotSchedule 교착 | Envoy Gateway 구성 |
| [09](09-ecr-credential-provider.md) | ECR 이미지 pull 실패 | K8s 1.27 in-tree 자격증명 공급자 제거 | Argo CD 최초 배포 |
| [10](10-container-nonroot.md) | 컨테이너 기동 실패 | `USER` 이름 표기, 이미지가 root 를 전제 | Argo CD 배포 |
| [11](11-cloudfront-host-header.md) | 프론트엔드 404 | CloudFront 가 Host 를 오리진 도메인으로 교체 | 검증 리소스 정리 후 |
| [12](12-redis-acl-pubsub.md) | 실시간 채팅 미동작 | Redis ACL 에 pubsub 명령 권한 없음 | 채팅 게이트웨이 배포 |

04와 05는 같은 증상의 서로 다른 원인이다. 04를 해결한 뒤에도 증상이 남아 05로 이어졌다.

**07은 04의 조치가 원인이었다.** kube-proxy 규칙을 제거하려고 iptables 를 직접
조작한 것이 Cilium 상태를 손상시켰고, 증상은 connectivity test 에서 드러났다.

**09와 10은 연속으로 발생했다.** 09를 해결해 이미지를 받게 되자
10이 드러났다. 하나를 고쳐야 다음 단계에서 막히는 것이 보인다.

**11은 검증용 리소스가 설정 오류를 덮고 있던 경우다.**
`nginx-test` HTTPRoute 가 hostnames 없이 모든 Host 를 받고 있었고,
그것을 지우자 CloudFront 설정 문제가 드러났다.

**12는 증상이 두 단계로 나타났다.** 구독 권한이 없어 게이트웨이가 죽었고,
그것을 고친 뒤에도 발행 권한이 없어 실시간이 동작하지 않았다.
후자는 애플리케이션이 예외를 삼켜 겉으로는 정상이었다.

## 분류

| 유형 | 해당 문서 |
| --- | --- |
| Security Group 설계 누락 | 02, 05, 06 |
| Kubespray 동작 특성 | 01, 04 |
| 환경 전제 불일치 | 03, 10 |
| 조치가 만든 2차 문제 | 07 |
| 매니페스트 문법·스케줄링 | 08 |
| 상위 버전에서 제거된 기능 | 09 |
| 기본값이 다른 전제를 가짐 | 11 |
| 권한 설계 누락 | 12 |

### SG 규칙

SG 규칙 누락이 초기 구축에서 가장 많았다. 한 문서에서 여러 규칙을
추가한 경우가 있어 문서 수와 규칙 수가 일치하지 않는다.

| 문서 | 추가한 규칙 |
| --- | --- |
| 02 | 6-b (etcd 멤버 간 2379) |
| 05 | 4-b, 4-c (apiserver 직접), 9-b (ICMP) |
| 06 | 7-b, 7-c, 7-d (kubelet API 방향) |

**설계 시 정의한 통신 경로가 실제 도구의 동작과 달랐던 경우다.**
포트 하나에 대해 출발지 × 목적지 조합을 모두 검토해야 한다.

### 배포 단계에서 드러난 유형

09~12 는 클러스터가 아니라 **서비스를 올리면서** 발생했다.
공통점은 **구성 요소가 서로에 대해 가진 전제가 어긋난 것**이다.

| 문서 | 어긋난 전제 |
| --- | --- |
| 09 | kubelet 이 ECR 인증을 내장하고 있을 것 |
| 10 | 이미지가 비root 로 동작하도록 만들어졌을 것 |
| 11 | CloudFront 가 Host 를 그대로 전달할 것 |
| 12 | ACL 이 필요한 명령을 이미 허용하고 있을 것 |

넷 모두 설정 자체는 문법상 올바랐고, 상대가 기대와 다르게 동작했다.

## 설계 변경으로 이어진 항목

| 항목 | 당초 | 변경 |
| --- | --- | --- |
| kube-proxy replacement | 미적용 | 적용 |
| etcd 2379 접근 | Control Plane만 | + 멤버 간 |
| apiserver 접근 경로 | Internal NLB 경유 | + Worker → CP, CP 간 직접 |
| kubelet API 10250 | CP → Worker만 | + CP 간, Worker → CP, Worker 간 |
| 노드 간 ICMP | 미허용 | 허용 |
| kubelet 자격증명 | 없음 (내장 전제) | `ecr-credential-provider` 설치 |
| 컨테이너 `USER` | 이름 | 숫자 UID |
| 프론트 베이스 이미지 | `nginx` | `nginxinc/nginx-unprivileged` |
| CloudFront Host 전달 | 미설정 | default·`/assets/*` 에 Host 전달 정책 |
| Redis ACL | `@read @write @connection` | + `@pubsub` |
| Redis 버전 | 7.0.15 (universe) | 8.10.2 (공식 저장소) |

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

### 애플리케이션이 원인을 감출 때

에러 메시지가 `error.name` 만 출력하면 어떤 예외든 같은 문자열이 나온다.
애플리케이션을 고치지 않고 원인을 보려면 **같은 이미지로 임시 Pod 를 띄워**
필요한 코드를 직접 실행한다.

```bash
kubectl -n <ns> run debug --restart=Never --image=<같은 이미지> \
  --overrides='{"spec":{"containers":[{"name":"debug","image":"<같은 이미지>",
    "command":["node","-e","...error.message 까지 출력하는 코드..."],
    "envFrom":[{"configMapRef":{"name":"<앱>"}},{"secretRef":{"name":"<앱>"}}]}]}}'
```

```bash
sleep 10 && kubectl -n <ns> logs debug && kubectl -n <ns> delete pod debug
```

`envFrom` 으로 실제 환경변수를 그대로 주입하는 것이 핵심이다.
설정 차이 때문에 재현되지 않는 일을 막는다.

`-it` 를 붙이면 TTY 할당 실패로 출력이 보이지 않을 수 있다.
`--restart=Never` 로 띄우고 `logs` 로 읽는 편이 확실하다.

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

### 외부 진입 경로 구간 분리

CloudFront 뒤에서 발생한 문제는 구간을 나눠 확인한다.
안쪽부터 확인하면 어디까지 정상인지 드러난다.

| 순서 | 구간 | 방법 |
| --- | --- | --- |
| 1 | Pod | `kubectl exec` 또는 Pod IP 직접 |
| 2 | Envoy | Worker NodePort + `Host` 헤더 |
| 3 | NLB | 타겟 그룹 health |
| 4 | CloudFront | 외부에서 `curl -I` |

```bash
# 2번. 세 노드 모두 확인한다
for ip in 10.20.10.20 10.20.11.20 10.20.12.20; do
  echo -n "$ip: "
  curl -s -o /dev/null -w "%{http_code}\n" -H "Host: re-used.store" http://$ip:30080/
done
```

```bash
# 3번
TG_ARN=$(aws elbv2 describe-target-groups --region ap-northeast-1 \
  --names <tg-name> --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region ap-northeast-1 \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```

**`x-cache: Error from cloudfront` 를 캐시 문제로만 읽지 않는다.**
오리진 응답이 에러였을 때도 이 값이 나온다. 무효화를 먼저 시도하면
진단이 늦어진다.

```bash
curl -sI "https://<도메인>/" | grep -i "x-cache\|age"
```

**Host 헤더를 바꿔가며 시험하면** 라우팅 문제를 빠르게 좁힐 수 있다.

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: re-used.store" http://<node>:30080/
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: origin.re-used.store" http://<node>:30080/
```

### 클라이언트별 명령 시퀀스 차이

CLI 로 되는 것이 애플리케이션에서 안 될 수 있다.
연결 직후 보내는 명령이 다르기 때문이다.

| 도구 | 연결 직후 |
| --- | --- |
| `redis-cli` | `AUTH` 후 사용자 명령만 |
| `node-redis` 5.x | `AUTH` → `CLIENT SETINFO` → 사용자 명령 |

**권한이나 호환성 문제는 실제 클라이언트로 검증한다.**
CLI 테스트가 통과했다고 애플리케이션이 붙는다는 뜻은 아니다.

### 컨트롤러 리소스 진단

Gateway API 나 CRD 기반 컨트롤러는 리소스 상태가 정상이어도
내부 처리가 실패하고 있을 수 있다. 에러가 컨트롤러 로그에만 남는다.

```bash
kubectl -n <ns> logs -l <controller-label> --tail=30 | grep -iE "error"
```

| 컴포넌트 | 라벨 |
| --- | --- |
| Envoy Gateway | `control-plane=envoy-gateway` |
| EBS CSI | `app=ebs-csi-controller` |
| kubelet-csr-approver | `app.kubernetes.io/name=kubelet-csr-approver` |
| External Secrets | `app.kubernetes.io/name=external-secrets` |
| Argo CD | `app.kubernetes.io/name=argocd-application-controller` |

리소스 status 의 `conditions` 도 함께 확인한다.

```bash
kubectl get <kind> <name> -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

### 로그 시점 구분

`--tail` 은 시간과 무관하게 마지막 N줄을 보여준다. 재부팅이나 Pod 재시작
직후에는 과거 로그가 잡히므로 `--since` 를 함께 쓴다.

```bash
kubectl -n <ns> logs <pod> --since=30s | grep -c "<에러 문자열>"
```

`0` 이면 최근 30초간 해당 에러가 없다는 뜻이다.

**Pod 가 여러 개면 라벨 셀렉터를 쓴다.** 요청이 어느 Pod 로 갔는지
모르는 상태에서 하나만 보면 놓친다.

```bash
kubectl -n <ns> logs -l app.kubernetes.io/name=<앱> --since=10m --prefix
```

### 삼켜진 예외 찾기

애플리케이션이 실패를 `warn` 으로만 남기면 서비스는 정상으로 보인다.
기능이 동작하지 않는데 에러가 없다면 경고 수준 로그를 훑는다.

```bash
kubectl -n <ns> logs -l app.kubernetes.io/name=<앱> --since=10m | grep -i "warn\|failed"
```

12번이 이 경우였다. Redis 발행이 실패하고 있었으나 `log.warn` 뿐이라
폴링이 화면을 갱신하는 동안 실시간이 되는 것처럼 보였다.

### 구성 변경 후 검증

Cilium 구성이나 노드 상태를 바꾼 뒤에는 기본 통신 확인만으로 부족하다.
L7 정책처럼 평소에 쓰지 않는 경로는 깨져 있어도 드러나지 않는다.

```bash
cilium connectivity test 2>&1 | tee /tmp/test.log
```

20분 소요. 결과 요약은 아래로 확인한다.

```bash
grep -E "tests failed|tests successful" /tmp/test.log | tail -3
grep "🟥" /tmp/test.log | grep -v "check-log-errors" | head -20
```

**현재 환경에서 예상되는 실패 2건.**

| 항목 | 사유 |
| --- | --- |
| `pod-to-hostport` | SG 에 hostPort 4000 없음. 사용하지 않는 기능 |
| `check-log-errors` | 재부팅 직후 restart count 와 과거 로그를 검출 |

cilium CLI 버전이 클러스터보다 낮으면 `v2alpha1 deprecated` 경고가 출력되고
일부 테스트 항목이 빠진다. CLI 를 클러스터 버전 이상으로 맞춘다.

```bash
curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt
cilium version
```

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
## 참고          관련 파일 경로
```

**오판한 과정도 남긴다.** 결론만 있으면 다음에 같은 함정에 빠진다.

일반화할 수 있는 내용이 있으면 `## 교훈` 을 추가한다.
진단 과정과 재발 방지에 이미 담겨 있다면 생략한다.

배경 지식이 필요하면 증상 앞에 `## 배경` 을 둔다.
용어나 구조를 모르면 진단 과정을 따라갈 수 없는 경우에 해당한다.

선택지를 비교한 뒤 결정했다면 원인과 해결 사이에 `## 대안 검토` 를 둔다.
왜 그 방법을 골랐는지가 해결 자체보다 중요한 경우가 있다.

한 문서에서 두 사건을 다루면 `## 1차` `## 2차` 로 나눈다.
증상은 달라도 원인이 같은 뿌리이거나, 하나를 고쳐야 다음이 드러나는 경우다.

**확인하지 못한 것은 확인하지 못했다고 쓴다.**
추정을 사실처럼 적으면 다음 사람이 그것을 근거로 판단한다.
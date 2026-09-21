# 02. etcd 클러스터 헬스체크 실패

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-21 |
| 단계 | `cluster.yml` 실행 중 (etcd 역할) |
| 영향 | etcd-a 실패, 플레이북 중단 → Kubernetes 설치 단계 진행 불가 |
| 환경 | Kubespray v2.31.0, External etcd 3 member |

## 증상

etcd 클러스터는 기동했으나 헬스체크 태스크가 4회 재시도 후 실패했다.

```
PLAY RECAP
etcd-a  : ok=124 failed=1
etcd-c  : ok=109 failed=0
etcd-d  : ok=109 failed=0
```

실패 내용.

```
fatal: [etcd-a]: FAILED! => {
  "attempts": 4,
  "cmd": "set -o pipefail && /usr/local/bin/etcdctl endpoint --cluster status
          && /usr/local/bin/etcdctl endpoint --cluster health ...",
  "rc": 1,
  "stderr": "Failed to get the status of endpoint https://10.20.22.10:2379 (context deadline exceeded)
             Failed to get the status of endpoint https://10.20.21.10:2379 (context deadline exceeded)",
  "stdout": "https://10.20.20.10:2379, 137d50b4f8887019, 3.6.10, ... "
}
```

**자기 자신(10.20.20.10)만 응답하고 나머지 두 멤버는 timeout.**

## 진단 과정

### 1. 서비스 상태 확인

```bash
ansible -i inventory/logssey/inventory.ini etcd -m shell -b \
  -a "systemctl is-active etcd"
```

```
etcd-a | active
etcd-c | active
etcd-d | active
```

3대 모두 정상 기동했다.

### 2. etcd 로그 확인

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "journalctl -u etcd -n 30 --no-pager"
```

```
msg="established TCP streaming connection with remote peer" remote-peer-id="7673295339eeac89"
msg="established TCP streaming connection with remote peer" remote-peer-id="407a16421f043dac"
msg="raft.node: 137d50b4f8887019 elected leader 7673295339eeac89 at term 2"
msg="ready to serve client requests"
msg="serving client traffic securely" address="10.20.20.10:2379"
```

**멤버 간 연결과 leader election 은 정상.** peer 포트(2380)는 통한다는 뜻이다.

### 3. 멤버 목록 조회

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "/usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/ssl/etcd/ssl/ca.pem \
      --cert=/etc/ssl/etcd/ssl/admin-etcd-a.pem \
      --key=/etc/ssl/etcd/ssl/admin-etcd-a-key.pem \
      member list -w table"
```

```
+------------------+---------+-------+--------------------------+--------------------------+
|        ID        | STATUS  | NAME  |        PEER ADDRS        |       CLIENT ADDRS       |
+------------------+---------+-------+--------------------------+--------------------------+
| 137d50b4f8887019 | started | etcd1 | https://10.20.20.10:2380 | https://10.20.20.10:2379 |
| 407a16421f043dac | started | etcd3 | https://10.20.22.10:2380 | https://10.20.22.10:2379 |
| 7673295339eeac89 | started | etcd2 | https://10.20.21.10:2380 | https://10.20.21.10:2379 |
+------------------+---------+-------+--------------------------+--------------------------+
```

3 멤버 모두 `started`. 이 조회는 etcd-a 가 로컬 데이터로 응답하므로
다른 멤버와의 통신 여부를 보여주지 않는다.

### 4. 클라이언트 포트 직접 테스트

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "timeout 3 bash -c 'echo > /dev/tcp/10.20.21.10/2379' ; echo exit=\$?"
```

```
exit=124
```

**timeout.** 포트가 차단되어 있다.

`exit=124`는 `timeout` 명령의 시간 초과 코드다.
포트가 열려 있으나 프로세스가 없으면 즉시 `Connection refused`(exit=1)가 나므로,
timeout 은 방화벽 차단을 의미한다.

## 원인

Security Group 에 **etcd 멤버 간 2379(클라이언트 포트) 규칙이 없었다.**

설계 문서에는 이렇게 정의되어 있었다.

```
Control Plane SG → etcd SG : TCP 2379   (클라이언트)
etcd SG → etcd SG : TCP 2380            (peer)
```

"Control Plane 에서만 etcd Client Port 2379 에 접근할 수 있도록 제한한다"는
전제가 실제와 달랐다.

Kubespray 의 헬스체크는 `etcdctl endpoint --cluster health` 를 실행하는데,
이 명령은 **etcd 노드에서 다른 멤버의 클라이언트 포트(2379)로 접속**한다.
peer 포트(2380)는 Raft 통신 전용이라 이 경로를 대체하지 않는다.

## 해결

Terraform 에 SG 규칙을 추가했다.

`terraform/modules/security/rules.tf`

```hcl
# ── 6-b. etcd → etcd (client) ──
# etcdctl 을 etcd 노드에서 실행할 때 다른 멤버의 2379 로 접속한다.
# Kubespray 의 endpoint health --cluster 체크가 이 경로를 사용한다.
resource "aws_vpc_security_group_ingress_rule" "etcd_client_internal" {
  security_group_id            = aws_security_group.etcd.id
  referenced_security_group_id = aws_security_group.etcd.id
  ip_protocol                  = "tcp"
  from_port                    = 2379
  to_port                      = 2379
  description                  = "etcd client between members"
}
```

```bash
cd terraform/environments/prod
terraform apply
```

적용 후 확인.

```bash
ansible -i inventory/logssey/inventory.ini etcd-a -m shell -b \
  -a "/usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/ssl/etcd/ssl/ca.pem \
      --cert=/etc/ssl/etcd/ssl/admin-etcd-a.pem \
      --key=/etc/ssl/etcd/ssl/admin-etcd-a-key.pem \
      endpoint health --cluster"
```

```
https://10.20.20.10:2379 is healthy: successfully committed proposal: took = 13.750912ms
https://10.20.21.10:2379 is healthy: successfully committed proposal: took = 19.924677ms
https://10.20.22.10:2379 is healthy: successfully committed proposal: took = 29.490712ms
```

## 재발 방지

- Terraform 에 규칙이 포함되어 재발하지 않는다.
- `docs/02-security.md` 의 체인 규칙 표에 6-b 항목을 추가했다.
- Notion [1. 네트워크] 문서의 Security Group Chain 도 함께 수정해야 한다.

## 교훈

**설계 시 정의한 통신 경로가 실제 도구의 동작과 다를 수 있다.**

"Control Plane 에서만 2379 접근"은 보안 관점에서 타당해 보였으나,
운영 도구(etcdctl)가 멤버 간 클라이언트 포트를 사용한다는 점을 반영하지 못했다.

포트 차단 여부는 `timeout` 종료 코드로 빠르게 판별할 수 있다.

| 결과 | 의미 |
| --- | --- |
| `exit=124` | timeout — 방화벽 차단 |
| `Connection refused` (exit=1) | 포트 도달, 프로세스 없음 |
| `exit=0` | 정상 연결 |

## 참고

| 항목 | 경로 |
| --- | --- |
| 헬스체크 태스크 | `roles/etcd/tasks/configure.yml` |
| SG 규칙 | `terraform/modules/security/rules.tf` |
| 설계 문서 | `docs/02-security.md` |
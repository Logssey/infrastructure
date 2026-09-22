# 09. Redis

> 설계 근거는 Notion [2. 데이터베이스] 참조

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| Redis 보안 | https://redis.io/docs/latest/operate/oss_and_stack/management/security/ |
| ACL | https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/ |
| 영속성 | https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/ |
| 메모리 최적화 | https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/memory-optimization/ |
| 설정 파일 | https://redis.io/docs/latest/operate/oss_and_stack/management/config/ |

---

## 구성

| 항목 | 값 |
| --- | --- |
| 배치 | EC2 redis-a (t3.small, 10.20.10.30) |
| 서브넷 | Private-App AZ-a |
| SG | sg-redis |
| 버전 | Redis 7.0.15 (Ubuntu 24.04 기본 패키지) |
| 포트 | 6379 |
| 설정 방식 | SSM 접속 후 수동 편집 |

### EC2 직접 설치

ElastiCache 가 아닌 EC2 에 직접 설치한다.

**데이터 성격이 RDS 와 다르기 때문이다.**

| 항목 | RDS | Redis |
| --- | --- | --- |
| 데이터 | 원본. 유실 시 복구 불가 | 캐시·세션. 재생성 또는 재로그인으로 해소 |
| 백업 요구 | PITR, 자동 스냅샷 필수 | AOF 로 충분 |
| 가용성 요구 | 중단 시 서비스 불가 | 중단 시 성능 저하와 재로그인 |

RDS 는 관리형이 제공하는 백업·복제·자동 복구가 그대로 가치가 된다.
Redis 는 그 기능들의 필요도가 낮아 관리형의 이점이 줄어든다.

| 항목 | ElastiCache | EC2 직접 설치 |
| --- | --- | --- |
| 비용 | 노드 요금 + 데이터 전송 | EC2 요금만 |
| 운영 부담 | AWS 관리 | 직접 |
| 설정 자유도 | 파라미터 그룹 범위 | redis.conf 전체 |
| 백업 | 자동 스냅샷 | 직접 구성 |

운영 부담은 감수한다. 실 트래픽이 없고 단일 인스턴스이므로
고가용성 구성이 필요하지 않다.

**부수 효과** — EC2 는 OS 패키지 취약점과 설정 미비가 스캔 대상이 된다.
관리형 서비스는 이 영역이 AWS 책임이라 스캔 재료가 제한적이다.


---

## 용도

두 가지를 한 인스턴스에서 처리한다.

| 용도 | 데이터 | 유실 시 영향 |
| --- | --- | --- |
| JWT 화이트리스트 | 발급된 토큰 목록 | **전체 사용자 로그아웃** |
| 데이터 캐싱 | 조회 결과 등 | 일시적 응답 지연 |

### 두 용도의 요구사항이 다르다

| 설정 | 캐시 | 토큰 저장소 |
| --- | --- | --- |
| `maxmemory-policy` | `allkeys-lru` | `noeviction` |
| 영속성 | 불필요 | 필요 |

경계는 **데이터를 버려도 되는가**다. 캐시는 버려도 되고 저장소는 안 된다.

실무에서는 **인스턴스 분리를 권장한다.**
`maxmemory-policy` 는 인스턴스 전역 설정이라, 캐시를 비우는 동작이
세션 데이터도 함께 지울 수 있기 때문이다.

### 단일 인스턴스로 운영하는 타협

인스턴스를 늘리면 비용이 2배가 된다. 트래픽 규모를 고려해
아래 조건으로 한 인스턴스에서 처리한다.

| 조건 | 내용 |
| --- | --- |
| 논리 분리 | db 0 = 캐시, db 1 = 토큰 |
| `maxmemory-policy` | `volatile-lru` — TTL 이 설정된 키만 evict 대상 |
| `maxmemory` | 1gb — evict 가 발생하지 않을 여유 |
| 영속성 | AOF 활성 |


---

## 보안

### 네트워크

| 계층 | 조치 |
| --- | --- |
| 서브넷 | Private-App. 인터넷에서 도달 불가 |
| SG | sg-worker 출발 6379 만 허용 (strict 모드) |
| `bind` | 10.20.10.30 |
| `protected-mode` | yes |

**`bind 0.0.0.0` 은 사용하지 않는다.**
사설 IP 를 명시해 해당 인터페이스로만 수신한다.

Redis 는 신뢰된 내부 네트워크를 전제로 설계되어 기본 설정이 느슨하다.
인증 없이 노출된 인스턴스는 cron 을 통한 SSH 키 주입, 암호화폐 채굴,
세션 토큰 탈취 등에 이용된 사례가 다수 보고되었다.

### 인증 — ACL

Redis 6 부터 ACL 을 지원한다. 본 환경은 7.0.15 이므로 사용 가능하다.

| 방식 | 특징 |
| --- | --- |
| `requirepass` | 단일 공유 비밀번호. 사용자 구분 없음 |
| **ACL** | 사용자별 권한. 명령 카테고리 단위 제어 |

ACL 구성.

```
user default off
user app on ><password> ~* &* +@all -@dangerous -@admin
```

| 항목 | 의미 |
| --- | --- |
| `default off` | 기본 계정 비활성화 |
| `~*` | 모든 키 패턴 접근 |
| `&*` | 모든 pub/sub 채널 |
| `+@all` | 모든 명령 허용 후 |
| `-@dangerous` | FLUSHALL, FLUSHDB, KEYS, DEBUG 등 제외 |
| `-@admin` | CONFIG, SHUTDOWN, REPLICAOF 등 제외 |

**`rename-command` 대신 ACL 을 쓰는 이유.**

| 항목 | rename-command | ACL |
| --- | --- | --- |
| 범위 | 인스턴스 전역 | 사용자별 |
| 변경 | 재시작 필요 | `ACL SETUSER` 로 즉시 |
| 감사 | 어려움 | 사용자 단위 추적 |

Redis 7 문서는 명령 제한에 ACL 사용을 권장한다.

**애플리케이션 연결 설정에 사용자명이 필요하다.**

```yaml
spring.data.redis.username: app
spring.data.redis.password: ${REDIS_PASSWORD}
```

`requirepass` 만 쓸 때와 달리 사용자명이 추가된다.

### 비밀번호 관리

**SSM Parameter Store SecureString** 에 저장한다.

| 항목 | 내용 |
| --- | --- |
| 생성 | 사람이 직접 생성 |
| 저장 | `aws ssm put-parameter --type SecureString` |
| 조회 | IAM 권한 기반 |
| 비용 | Standard tier 무료 (파라미터 10,000개까지) |

**Terraform 이 관여하지 않는다.**
Terraform 이 값을 알면 상태 파일에 평문으로 기록되기 때문이다.

RDS 는 `manage_master_user_password` 로 AWS 가 Secrets Manager 에
비밀번호를 생성·저장하나, Redis 는 EC2 에 직접 설치한 것이라
AWS 가 관여하지 않는다. 방식이 다른 이유다.

```bash
# 비밀번호 생성 및 등록
PASSWORD=$(openssl rand -base64 32)

aws ssm put-parameter \
  --name /logssey/prod/redis/password \
  --value "$PASSWORD" \
  --type SecureString \
  --region ap-northeast-1
```

```bash
# 조회
aws ssm get-parameter \
  --name /logssey/prod/redis/password \
  --with-decryption \
  --region ap-northeast-1 \
  --query 'Parameter.Value' --output text
```

### 파일 권한

`redis.conf` 에는 ACL 비밀번호가 평문으로 들어간다.

```bash
sudo chmod 640 /etc/redis/redis.conf
sudo chown redis:redis /etc/redis/redis.conf
```

Redis 프로세스는 `redis` 사용자로 실행된다. 패키지 설치 시 자동 설정되며
root 로 실행하지 않는다.

### TLS 미적용

VPC 내부 통신이며 Private-App 서브넷에서만 접근 가능하다.
TLS 를 적용하면 인증서 관리 부담이 생기므로 1차 구축에서는 제외한다.

외부 노출이 필요해지거나 규제 요구가 생기면 `tls-port` 로 전환한다.

---

## 메모리와 영속성

### maxmemory

| 항목 | 값 |
| --- | --- |
| 인스턴스 메모리 | 2 GiB (t3.small) |
| `maxmemory` | 1gb |

**절반만 할당하는 이유.**

Redis 는 `maxmemory` 를 데이터 저장에만 사용한다.
복제 버퍼, 클라이언트 출력 버퍼, 메모리 단편화, OS 와 다른 프로세스가
나머지를 쓴다.

`maxmemory` 를 물리 메모리에 가깝게 잡으면 OOM Killer 가
Redis 프로세스를 종료시킬 수 있다.

### maxmemory-policy

`volatile-lru` 를 사용한다.

| 정책 | 동작 |
| --- | --- |
| `noeviction` | 메모리 초과 시 쓰기 거부 (기본값) |
| `allkeys-lru` | 모든 키 대상. 가장 오래 사용되지 않은 것부터 |
| **`volatile-lru`** | **TTL 이 설정된 키만 대상** |
| `volatile-ttl` | TTL 이 설정된 키 중 만료가 가까운 것부터 |

**`volatile-*` 정책은 TTL 이 없는 키를 건드리지 않는다.**

다만 본 환경은 캐시와 토큰 모두 TTL 을 사용한다.
캐시는 갱신 주기를, 토큰은 만료 시간을 TTL 로 설정하므로
둘 다 evict 대상이 된다.

evict 자체가 발생하지 않도록 `maxmemory` 에 여유를 두는 것이
실질적인 방어다. 메모리 사용량을 주시하고 한계에 근접하면
인스턴스 분리를 검토한다.

### 영속성 — AOF

| 항목 | 값 |
| --- | --- |
| `appendonly` | yes |
| `appendfsync` | everysec |
| RDB | 기본 `save` 설정 유지 |

**AOF 를 켜는 이유는 재시작 시 토큰 유실을 막기 위함이다.**
JWT 화이트리스트가 사라지면 로그인된 사용자가 전부 튕긴다.

| `appendfsync` | 내구성 | 성능 |
| --- | --- | --- |
| `always` | 명령마다 디스크 기록 | 느림 |
| **`everysec`** | 최대 1초 손실 | 균형 |
| `no` | OS 에 위임 | 빠름 |

`everysec` 이 일반적인 선택이다.

RDB 스냅샷도 함께 유지한다. AOF 는 복구 시간이 길고,
RDB 는 백업 파일로 다루기 쉽다. 두 방식을 병행하면
빠른 복구와 정확한 복구를 모두 확보할 수 있다.

---

## 설정 절차

user_data 는 패키지 설치만 수행하고 **서비스를 중지·비활성 상태로 둔다.**
기본 설정(`bind 127.0.0.1`, 인증 없음)으로 기동되는 것을 막기 위함이다.

```bash
systemctl stop redis-server
systemctl disable redis-server
```

`docs/04-compute.md` 의 user_data 절 참조.

### 1. 접속

```bash
cd terraform/environments/prod
REDIS_ID=$(terraform output -raw redis_instance_id)

aws ssm start-session --target $REDIS_ID --region ap-northeast-1
```

### 2. 비밀번호 준비

로컬에서 생성해 Parameter Store 에 등록한 뒤, 노드에서 조회한다.

```bash
sudo su -
PASSWORD=$(aws ssm get-parameter \
  --name /logssey/prod/redis/password \
  --with-decryption --region ap-northeast-1 \
  --query 'Parameter.Value' --output text)
```

노드 IAM Role 에 `ssm:GetParameter` 와 KMS 복호화 권한이 필요하다.
`AmazonSSMManagedInstanceCore` 에 포함되어 있다.

### 3. redis.conf 편집

```bash
cp /etc/redis/redis.conf /etc/redis/redis.conf.bak
```

아래 항목을 설정한다.

```
bind 10.20.10.30
protected-mode yes
port 6379

maxmemory 1gb
maxmemory-policy volatile-lru

appendonly yes
appendfsync everysec

user default off
user app on ><password> ~* &* +@all -@dangerous -@admin
```

`<password>` 는 2단계에서 조회한 값으로 치환한다.

### 4. 권한 설정

```bash
chmod 640 /etc/redis/redis.conf
chown redis:redis /etc/redis/redis.conf
```

### 5. 기동

```bash
systemctl enable redis-server
systemctl start redis-server
systemctl status redis-server
```

---

## 검증

### 서비스 상태

```bash
systemctl is-active redis-server
redis-cli --user app --pass <password> ping
```

인증 없이 접속하면 거부되어야 한다.

```bash
redis-cli ping
# (error) NOAUTH Authentication required.
```

### 설정 확인

```bash
redis-cli --user app --pass <password> CONFIG GET maxmemory
redis-cli --user app --pass <password> CONFIG GET maxmemory-policy
redis-cli --user app --pass <password> CONFIG GET appendonly
```

`CONFIG` 는 `-@admin` 으로 제한했으므로 app 사용자로는 실패한다.
서버에서 기본 계정을 일시적으로 활성화하거나 `redis.conf` 를 직접 확인한다.

### ACL 확인

```bash
redis-cli --user app --pass <password> ACL WHOAMI
# app

redis-cli --user app --pass <password> FLUSHALL
# (error) NOPERM ... has no permissions to run the 'flushall' command
```

위험 명령이 차단되는지 확인한다.

### 네트워크 확인

Worker 노드에서 포트 도달 여부를 본다.

```bash
ansible -i inventory/logssey/inventory.ini worker-a -m shell -b \
  -a "timeout 3 bash -c 'echo > /dev/tcp/10.20.10.30/6379'; echo exit=\$?"
```

`exit=0` 이어야 한다.

### Pod 에서 연결

```bash
kubectl run redistest --rm -it --image=redis:7-alpine --restart=Never -- \
  redis-cli -h 10.20.10.30 --user app --pass <password> ping
```

### db 분리 확인

```bash
redis-cli -h 10.20.10.30 --user app --pass <password> -n 0 SET cache:test 1
redis-cli -h 10.20.10.30 --user app --pass <password> -n 1 GET cache:test
# (nil)
```

db 0 에 쓴 값이 db 1 에서 보이지 않아야 한다.

---

## 비용

| 항목 | 월 (USD) |
| --- | --- |
| EC2 t3.small | 약 19 |
| EBS gp3 20GB | 약 2 |
| SSM Parameter Store | 0 |
| **합계** | **약 21** |

도쿄 리전 기준, 730시간 환산. `docs/04-compute.md` 의 전체 비용에 포함되어 있다.

---

## 미해결 항목

| 항목 | 내용 |
| --- | --- |
| SSH 경로 | `sg-redis` 에 SSH 인바운드 규칙이 없다 |
| 공개키 | Kubespray 공개키 배포 시 Redis 노드는 제외했다 |

**Ansible 로 설정을 관리하려면 둘 다 필요하다.**
현재는 SSM 으로 접속해 수동 설정하므로 문제가 없다.

Ansible 전환 시 아래를 추가한다.

```hcl
resource "aws_vpc_security_group_ingress_rule" "redis_ssh_from_k8s_node" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.k8s_node.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "Ansible SSH from control plane"
}
```

---

## 확장 항목

| 항목 | 시점 |
| --- | --- |
| 인스턴스 분리 (캐시 / 토큰) | 메모리 사용량이 maxmemory 에 근접할 때 |
| Ansible 설정 관리 | 노드가 늘거나 재현성이 필요할 때 |
| TLS | 외부 노출 또는 규제 요구 발생 시 |
| Redis Sentinel / Cluster | 고가용성 요구 발생 시 |
| ElastiCache 전환 | 운영 부담이 커질 때 |
| 백업 자동화 | RDB 파일을 S3 로 주기 전송 |
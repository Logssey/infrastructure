# 09. Redis

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| Redis 보안 | https://redis.io/docs/latest/operate/oss_and_stack/management/security/ |
| ACL | https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/ |
| 영속성 | https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/ |
| 메모리 최적화 | https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/memory-optimization/ |
| 설정 파일 | https://redis.io/docs/latest/operate/oss_and_stack/management/config/ |
| 공식 APT 저장소 | https://redis.io/docs/latest/operate/oss_and_stack/install/archive/install-redis/install-redis-on-linux/ |

---

## 구성

| 항목 | 값 |
| --- | --- |
| 배치 | EC2 redis-a (t3.small, 10.20.10.30) |
| 서브넷 | Private-App AZ-a |
| SG | sg-redis |
| 버전 | Redis 8.10.2 (공식 APT 저장소) |
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

### 공식 저장소에서 설치하는 이유

Ubuntu 24.04 universe 저장소는 **7.0.15 에서 멈춰 있다.**

채팅 게이트웨이가 쓰는 `node-redis` 는 연결 직후 `CLIENT SETINFO` 로
라이브러리 이름과 버전을 서버에 알린다. 이 명령은 **Redis 7.2 에 도입**되어
7.0 에서는 `unknown subcommand` 로 실패한다.

`redis-cli` 는 이 명령을 보내지 않아 정상 접속되므로,
서버는 멀쩡해 보이는데 애플리케이션만 붙지 못하는 상황이 된다.

**패키지 이름이 다르다.**

| 저장소 | 패키지 |
| --- | --- |
| Ubuntu universe | `redis-server` |
| 공식 packages.redis.io | `redis` |

둘을 섞으면 systemd 유닛과 설정 경로가 충돌한다.
전환할 때는 한쪽을 완전히 제거한 뒤 설치한다.

---

## 용도

세 가지를 한 인스턴스에서 처리한다.

| 용도 | 데이터 | 유실 시 영향 |
| --- | --- | --- |
| JWT 화이트리스트 | 발급된 토큰 목록 | **전체 사용자 로그아웃** |
| 데이터 캐싱 | 조회 결과 등 | 일시적 응답 지연 |
| 채팅 Pub/Sub | 실시간 이벤트 전달 | 실시간 수신 중단 |

### 채팅 Pub/Sub

Spring API 가 메시지를 저장한 뒤 `reused:chat:room:{id}` 채널로 발행하고,
채팅 게이트웨이(`reused-chat`)가 패턴 구독으로 받아 연결된 클라이언트에 전달한다.

```
Spring API ──PUBLISH──> Redis ──PSUBSCRIBE──> chat gateway ──Socket.IO──> 브라우저
```

Pub/Sub 은 저장되지 않는 휘발성 경로다. 구독자가 없는 동안 발행된 이벤트는
사라지므로, 클라이언트는 재연결 후 REST 로 메시지 목록을 다시 읽는다.

**이 용도 때문에 ACL 에 pubsub 권한이 필요하다.** 아래 인증 절 참조.

### 용도별 요구사항이 다르다

| 설정 | 캐시 | 토큰 저장소 |
| --- | --- | --- |
| `maxmemory-policy` | `allkeys-lru` | `noeviction` |
| 영속성 | 불필요 | 필요 |

경계는 **데이터를 버려도 되는가**다. 캐시는 버려도 되고 저장소는 안 된다.
Pub/Sub 은 메모리에 남지 않아 이 구분과 무관하다.

실무에서는 **인스턴스 분리를 권장한다.**
`maxmemory-policy` 는 인스턴스 전역 설정이라, 캐시를 비우는 동작이
세션 데이터도 함께 지울 수 있기 때문이다.

### 단일 인스턴스로 운영하는 타협

인스턴스를 늘리면 비용이 2배가 된다. 트래픽 규모를 고려해
아래 조건으로 한 인스턴스에서 처리한다.

| 조건 | 내용 |
| --- | --- |
| 논리 분리 | db 0 = 캐시, db 1 = 토큰 |
| `maxmemory-policy` | `volatile-lru` |
| `maxmemory` | 1gb |
| 영속성 | AOF 활성 |

상세는 아래 메모리 절 참조.

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

Redis 6 부터 ACL 을 지원한다.

| 방식 | 특징 |
| --- | --- |
| `requirepass` | 단일 공유 비밀번호. 사용자 구분 없음 |
| **ACL** | 사용자별 권한. 명령 카테고리 단위 제어 |

**`rename-command` 대신 ACL 을 쓴다.**

| 항목 | rename-command | ACL |
| --- | --- | --- |
| 범위 | 인스턴스 전역 | 사용자별 |
| 변경 | 재시작 필요 | `ACL SETUSER` 로 즉시 |
| 감사 | 어려움 | 사용자 단위 추적 |

Redis 7 문서는 명령 제한에 ACL 사용을 권장한다.

#### 별도 파일로 관리

`redis.conf` 에 ACL 을 직접 쓰지 않고 `aclfile` 로 분리한다.

```
aclfile /etc/redis/acl-users.conf
```

| 이점 | 내용 |
| --- | --- |
| 비밀번호 분리 | `redis.conf` 에 비밀번호가 남지 않는다 |
| 런타임 리로드 | `ACL LOAD` 로 재시작 없이 반영 |
| 권한 관리 | ACL 파일만 640 으로 제한 |

#### ACL 파일은 주석과 빈 줄을 허용하지 않는다

**`redis.conf` 와 규칙이 다르다.** 모든 줄이 `user` 로 시작해야 한다.

주석을 넣으면 기동이 실패한다.

```
# Aborting Redis startup because of ACL errors:
# /etc/redis/acl-users.conf:1 should start with user keyword followed by the username.
```

설명은 `redis.conf` 의 `aclfile` 지시어 근처나 이 문서에 남긴다.

#### 구성

```
user default off
user app on ><password> ~* &* +@read +@write +@connection -@dangerous +@pubsub
```

| 항목 | 의미 |
| --- | --- |
| `default off` | 기본 계정 비활성화 |
| `~*` | 모든 **키** 패턴 접근 |
| `&*` | 모든 **채널** 패턴 접근 |
| `+@read +@write` | 데이터 조작 명령 |
| `+@connection` | CLIENT SETNAME 등. 일부 클라이언트가 연결 시 사용 |
| `+@pubsub` | PUBLISH, SUBSCRIBE, PSUBSCRIBE 등 |
| `-@dangerous` | FLUSHALL, FLUSHDB, KEYS, DEBUG 등 제외 |

#### 채널 패턴과 명령 권한은 별개다

**둘 다 있어야 Pub/Sub 이 동작한다.**

| 항목 | 통제 대상 |
| --- | --- |
| `&*` | 어떤 채널에 접근해도 되는가 |
| `+@pubsub` | 해당 명령을 실행할 수 있는가 |

`&*` 만 있고 `+@pubsub` 이 없으면 채널은 열려 있으나 명령이 거부된다.
문을 열어 두고 들어갈 자격은 주지 않은 셈이다.

```
NOPERM User app has no permissions to run the 'psubscribe' command
```

초기 구성은 `+@read +@write +@connection` 뿐이었고 pubsub 계열이 빠져 있었다.
캐시와 세션만 쓰던 동안에는 드러나지 않다가 채팅 게이트웨이를 붙이면서 발견됐다.

**증상이 두 단계로 나타났다.**

| 주체 | 필요한 명령 | 실패 양상 |
| --- | --- | --- |
| 채팅 게이트웨이 | `PSUBSCRIBE` | 기동 실패. CrashLoopBackOff |
| Spring API | `PUBLISH` | 예외를 삼키고 경고만 남김. 겉으로는 정상 |

두 번째가 까다로웠다. 애플리케이션이 발행 실패를 `log.warn` 으로만 처리해
서비스는 정상 동작하는 것처럼 보였고, 프론트의 30초 폴링이 화면을 갱신해
실시간이 되는 것처럼 착각하게 만들었다.

**권한 부여 방향이 중요하다.**

| 방식 | 의미 |
| --- | --- |
| `+@all -@dangerous -@admin` | 전부 주고 위험한 것만 뺌 |
| **`+@read +@write +@pubsub -@dangerous`** | 필요한 것만 줌 |

최소 권한 원칙에 맞는 것은 후자다.
다만 **필요한 카테고리를 빠뜨리면 조용히 실패한다**는 비용이 따른다.
용도가 늘어날 때마다 ACL 을 함께 검토한다.

`~*` 로 둔 것은 백엔드 키 네이밍이 확정되지 않았기 때문이다.
확정되면 `~cache:* ~token:*` 식으로 좁힌다.
채널도 마찬가지로 `&reused:chat:*` 로 좁힐 수 있다.

#### INFO 는 부여하지 않는다

`INFO` 는 `@admin` 카테고리에 속해 app 계정에서 실행할 수 없다.

```
NOPERM this user has no permissions to run the 'info' command
```

실무 표준은 **애플리케이션 계정과 모니터링 계정을 분리**하는 것이다.
모니터링 도구를 도입할 때 전용 계정을 만든다.

```
user monitor on ><password> ~* +@read +info +dbsize +slowlog +latency +client|list -@write -@admin -@dangerous
```

Percona PMM 공식 문서도 같은 패턴을 안내한다.

모니터링 도구가 없는 상태에서 계정만 만들면 관리 대상과
비밀번호만 늘어나므로 지금은 생성하지 않는다.

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

노드 IAM Role 의 `AmazonSSMManagedInstanceCore` 로
SecureString 복호화까지 가능하다(확인됨).

#### 애플리케이션에는 Secrets Manager 로 전달한다

Parameter Store 는 **생성·보관** 용도이고,
Pod 가 읽는 경로는 **Secrets Manager** 다.

| 저장소 | 키 | 소비 |
| --- | --- | --- |
| SSM Parameter Store | `/logssey/prod/redis/password` | Terraform, 수동 조회 |
| Secrets Manager | `reused/prod/api` → `SPRING_DATA_REDIS_PASSWORD` | ESO → Pod |
| Secrets Manager | `reused/prod/chat` → `CHAT_REDIS_URL` | ESO → Pod |

**같은 값이 두 곳에 존재하므로 동기화가 깨질 수 있다.**
실제로 Parameter Store 에만 있고 Secrets Manager 에 반영되지 않아
`WRONGPASS` 로 기동이 막힌 적이 있다.

비밀번호를 바꾸면 세 곳을 모두 갱신한다.

1. ACL 파일
2. SSM Parameter Store
3. Secrets Manager (`reused/prod/api`, `reused/prod/chat`)

채팅용 `CHAT_REDIS_URL` 은 비밀번호를 URL 에 포함하므로
**URL 인코딩**이 필요하다.

```bash
python3 -c "
import urllib.parse, sys
print('redis://app:' + urllib.parse.quote(sys.argv[1], safe='') + '@10.20.10.30:6379')
" "$PASSWORD"
```

### 파일 권한

`acl-users.conf` 에는 비밀번호가 평문으로 들어간다.

```bash
chmod 640 /etc/redis/acl-users.conf
chown redis:redis /etc/redis/acl-users.conf
```

Redis 프로세스는 `redis` 사용자로 실행된다. 패키지 설치 시 자동 설정되며
root 로 실행하지 않는다.

### TLS 미적용

VPC 내부 통신이며 Private-App 서브넷에서만 접근 가능하다.
TLS 를 적용하면 인증서 관리 부담이 생기므로 1차 구축에서는 제외한다.

외부 노출이 필요해지거나 규제 요구가 생기면 `tls-port` 로 전환한다.

---

## 프로세스 관리

### daemonize 와 systemd

**Redis 8 의 systemd 유닛은 `Type=notify` 다.**

```bash
grep "^Type=" /usr/lib/systemd/system/redis-server.service
# Type=notify
```

`Type=notify` 는 프로세스가 준비 완료를 systemd 에 알리기를 기다린다.
`daemonize yes` 로 두면 Redis 가 포크한 뒤 부모가 종료되므로
systemd 는 기동 실패로 판단하고 SIGTERM 을 보낸다.

```
redis-server.service: Failed with result 'protocol'
```

로그에는 Redis 가 정상 기동한 직후 종료되는 흔적이 남는다.

```
* Server initialized
* Ready to accept connections
signal-handler Received SIGTERM scheduling shutdown...
```

**설정은 아래와 같아야 한다.**

```
daemonize no
supervised systemd
```

Ubuntu universe 패키지(7.0)는 `Type=forking` 이라 `daemonize yes` 가 맞았다.
공식 패키지로 전환할 때 함께 바꾼다.

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

Redis 7 부터 AOF 는 `appendonlydir/` 디렉터리에
base 파일과 incr 파일로 나뉘어 저장된다.

### 커널 파라미터 — vm.overcommit_memory

```
vm.overcommit_memory = 1
```

Redis 는 RDB 저장과 AOF 재작성에 `fork()` 를 사용한다.
리눅스 기본 설정에서는 부모 프로세스만큼의 메모리가 필요하다고 판단해
저메모리 상황에서 실패할 수 있다.

설정하지 않으면 기동 시마다 경고가 남는다.

```
WARNING Memory overcommit must be enabled! Without it, a background save
or replication may fail under low memory condition.
```

user_data 에 포함되어 있다.

---

## 설정 절차

user_data 는 공식 저장소 등록, 패키지 설치, 커널 파라미터 설정만 수행하고
**서비스를 중지·비활성 상태로 둔다.**
기본 설정(`bind 127.0.0.1`, 인증 없음)으로 기동되는 것을 막기 위함이다.

`terraform/modules/compute/templates/redis.sh` 참조.

### 1. 비밀번호 생성 및 등록

로컬에서 수행한다.

```bash
PASSWORD=$(openssl rand -base64 32)

aws ssm put-parameter \
  --name /logssey/prod/redis/password \
  --value "$PASSWORD" \
  --type SecureString \
  --region ap-northeast-1
```

### 2. 노드 접속

```bash
cd terraform/environments/prod
REDIS_ID=$(terraform output -raw redis_instance_id)

aws ssm start-session --target $REDIS_ID --region ap-northeast-1
```

```bash
sudo su -
```

### 3. 비밀번호 조회

```bash
PASSWORD=$(aws ssm get-parameter \
  --name /logssey/prod/redis/password \
  --with-decryption --region ap-northeast-1 \
  --query 'Parameter.Value' --output text)
```

AWS CLI 는 user_data 에서 설치된다.
**Ubuntu 24.04 저장소에는 `awscli` 패키지가 없으므로**
공식 설치 스크립트를 사용한다.

### 4. redis.conf 편집

```bash
cp /etc/redis/redis.conf /etc/redis/redis.conf.bak
```

기존 값을 치환한다.

```bash
sed -i 's/^bind 127.0.0.1 -::1/bind 10.20.10.30/' /etc/redis/redis.conf
sed -i 's/^appendonly no/appendonly yes/' /etc/redis/redis.conf
sed -i 's/^daemonize yes/daemonize no/' /etc/redis/redis.conf
```

없는 항목을 추가한다.

```bash
cat >> /etc/redis/redis.conf << 'EOF'

# systemd 유닛이 Type=notify 다. 포크하면 기동 실패로 처리된다.
supervised systemd

# 인스턴스 메모리 2GiB 중 절반.
# 복제 버퍼, 클라이언트 출력 버퍼, 단편화, OS 가 나머지를 사용한다.
maxmemory 1gb

# TTL 이 설정된 키만 evict 대상.
maxmemory-policy volatile-lru

# ACL 은 별도 파일로 관리한다.
aclfile /etc/redis/acl-users.conf
EOF
```

### 5. ACL 파일 생성

**주석과 빈 줄을 넣지 않는다.** 기동이 실패한다.

```bash
cat > /etc/redis/acl-users.conf << EOF
user default off
user app on >$PASSWORD ~* &* +@read +@write +@connection -@dangerous +@pubsub
EOF
```

붙여넣기로 작성하면 줄이 깨지는 경우가 있다. 반드시 결과를 확인한다.

```bash
cat /etc/redis/acl-users.conf
```

### 6. 권한 설정

```bash
chmod 640 /etc/redis/redis.conf /etc/redis/redis.conf.bak /etc/redis/acl-users.conf
chown redis:redis /etc/redis/redis.conf /etc/redis/redis.conf.bak /etc/redis/acl-users.conf
```

### 7. 기동

```bash
systemctl enable redis-server
systemctl start redis-server
systemctl status redis-server --no-pager
```

`Status: "Ready to accept connections"` 가 보이면 정상이다.

기동에 실패하면 로그를 확인한다.
`systemctl status` 만으로는 원인이 드러나지 않는다.

```bash
journalctl -u redis-server -n 30 --no-pager
tail -20 /var/log/redis/redis-server.log
```

---

## 기존 인스턴스 업그레이드

7.0(universe) 에서 8.x(공식) 로 옮기는 절차다.
신규 구축은 user_data 가 처리하므로 이 절은 기존 노드에만 해당한다.

### 사전 백업

```bash
mkdir -p /root/redis-backup
cp /etc/redis/redis.conf /etc/redis/acl-users.conf /root/redis-backup/
cp /usr/lib/systemd/system/redis-server.service /root/redis-backup/
```

### 주의 — purge 가 데이터 디렉터리까지 지운다

```bash
apt remove --purge -y redis-server redis-tools
```

이 명령은 `/etc/redis` 와 **`/var/lib/redis` 를 함께 삭제한다.**
RDB 와 AOF 파일이 사라진다.

세션과 캐시만 담고 있다면 감수할 수 있으나
**미리 알고 진행해야 한다.** 보존이 필요하면 먼저 복사한다.

```bash
cp -a /var/lib/redis /root/redis-data-backup
```

### 절차

```bash
# 1. 중지
systemctl stop redis-server

# 2. 기존 패키지 제거
apt remove --purge -y redis-server redis-tools

# 3. 공식 저장소 등록
apt install -y gnupg lsb-release
curl -fsSL https://packages.redis.io/gpg \
  | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/redis.list
apt update

# 4. 설치. 설치 직후 기본 설정으로 자동 기동되므로 곧바로 멈춘다
apt install -y redis
systemctl stop redis-server
redis-server --version

# 5. 설정 복원
cp /root/redis-backup/redis.conf /etc/redis/redis.conf
cp /root/redis-backup/acl-users.conf /etc/redis/acl-users.conf
chown redis:redis /etc/redis/redis.conf /etc/redis/acl-users.conf
chmod 640 /etc/redis/redis.conf /etc/redis/acl-users.conf

# 6. Redis 8 요구사항 반영
sed -i 's/^daemonize yes/daemonize no/' /etc/redis/redis.conf
grep -q "^supervised" /etc/redis/redis.conf || echo "supervised systemd" >> /etc/redis/redis.conf

# 7. ACL 에 +@pubsub 추가. 파일을 직접 편집하고 결과를 확인한다

# 8. 기동
systemctl start redis-server
systemctl status redis-server --no-pager
```

### 업그레이드 후 확인

```bash
redis-cli -h 10.20.10.30 --user app --askpass client setinfo lib-name node-redis
```

`OK` 가 나와야 한다. 7.0 에서는 `unknown subcommand` 였다.

애플리케이션 Pod 는 별도로 재시작한다.
Redis 재시작으로 커넥션이 끊기지만 환경변수는 기동 시 한 번만 읽으므로,
비밀번호나 접속 정보가 바뀌었다면 재시작이 필요하다.

```bash
kubectl -n reused rollout restart deployment reused-api reused-chat
```

---

## 검증

### 인증

```bash
redis-cli -h 10.20.10.30 ping
```

```
(error) NOAUTH Authentication required.
```

`default` 계정을 비활성화했으므로 인증 없이 접속할 수 없다.

```bash
redis-cli -h 10.20.10.30 --user app --pass "$PASSWORD" ping
```

```
PONG
```

### 데이터 조작

```bash
redis-cli -h 10.20.10.30 --user app --pass "$PASSWORD" SET test:key 1
redis-cli -h 10.20.10.30 --user app --pass "$PASSWORD" GET test:key
redis-cli -h 10.20.10.30 --user app --pass "$PASSWORD" DEL test:key
```

### Pub/Sub

**구독과 발행을 모두 확인한다.** 한쪽만 되는 경우가 있다.

터미널 하나에서 구독한다.

```bash
redis-cli -h 10.20.10.30 --user app --askpass psubscribe 'reused:chat:room:*'
```

다른 터미널에서 발행한다.

```bash
redis-cli -h 10.20.10.30 --user app --askpass publish 'reused:chat:room:1' 'test'
```

구독 쪽에 `pmessage` 가 찍히면 정상이다.
`NOPERM` 이 나오면 ACL 에 `+@pubsub` 이 빠진 것이다.

### 권한 차단

```bash
redis-cli -h 10.20.10.30 --user app --pass "$PASSWORD" FLUSHALL
redis-cli -h 10.20.10.30 --user app --pass "$PASSWORD" INFO memory
redis-cli -h 10.20.10.30 --user app --pass "$PASSWORD" CONFIG GET maxmemory
```

전부 `NOPERM` 이어야 한다.

### 설정 확인

`CONFIG` 와 `INFO` 가 차단되어 있으므로 서버에서 파일을 직접 확인한다.

```bash
grep -E "^(bind|daemonize|supervised|appendonly|appendfsync|maxmemory|aclfile)" /etc/redis/redis.conf
ls -la /var/lib/redis/
```

`appendonlydir/` 이 생성되어 있으면 AOF 가 동작하는 것이다.

### Pod 에서 연결

Control Plane 노드에서 실행한다.

```bash
kubectl run redistest --restart=Never \
  --image=redis:8-alpine \
  -- redis-cli -h 10.20.10.30 --user app --pass '<password>' ping

kubectl get pod redistest
kubectl logs redistest
kubectl delete pod redistest
```

`PONG` 이 나오면 Worker Pod 에서 Redis 까지 경로가 열린 것이다.

이미지를 받는 데 시간이 걸리므로 `kubectl get pod` 로
`Completed` 를 확인한 뒤 로그를 조회한다.

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
| 서브넷 계층 | Private-App 에 있다. 저장소이므로 Private-Data 가 맞다 |
| 비밀번호 이중 관리 | Parameter Store 와 Secrets Manager 에 같은 값이 존재한다 |

**SSH 는 Ansible 로 설정을 관리하려면 둘 다 필요하다.**
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

**서브넷 계층**은 RDS 와 같은 Private-Data 로 옮기는 것이 일관적이다.
현재는 SG 로 Worker 만 허용하고 있어 실질적 위험은 낮으나,
계층 방어 관점에서는 한 겹이 부족하다. 재생성 시 함께 처리한다.

---

## 확장 항목

| 항목 | 시점 |
| --- | --- |
| 모니터링 전용 ACL 계정 | Prometheus exporter 등 도입 시 |
| 키 패턴 제한 (`~cache:* ~token:*`) | 백엔드 키 네이밍 확정 후 |
| 채널 패턴 제한 (`&reused:chat:*`) | 채널 네이밍 확정 후 |
| 인스턴스 분리 (캐시 / 토큰) | 메모리 사용량이 maxmemory 에 근접할 때 |
| Ansible 설정 관리 | 노드가 늘거나 재현성이 필요할 때 |
| TLS | 외부 노출 또는 규제 요구 발생 시 |
| Redis Sentinel / Cluster | 고가용성 요구 발생 시 |
| ElastiCache 전환 | 운영 부담이 커질 때 |
| 백업 자동화 | RDB 파일을 S3 로 주기 전송 |
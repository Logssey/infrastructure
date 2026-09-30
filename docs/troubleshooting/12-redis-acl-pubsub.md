# 12. 실시간 채팅 미동작 — Redis ACL pubsub 권한 누락

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-29 |
| 단계 | 채팅 게이트웨이 배포 |
| 영향 | 게이트웨이 기동 불가 → 해결 후에도 실시간 전달 안 됨 |
| 환경 | Redis 7.0.15 → 8.10.2, node-redis 5.x, Socket.IO 4.8 |

## 배경

실시간 채팅은 Redis Pub/Sub 을 경유한다.

```
Spring API ──PUBLISH──> Redis ──PSUBSCRIBE──> chat gateway ──Socket.IO──> 브라우저
```

게이트웨이는 메시지를 저장하지 않는다. `reused:chat:room:{id}` 채널을
패턴 구독하다가 이벤트가 오면 "이 방이 바뀌었다"는 신호만 보내고,
클라이언트는 REST 로 내용을 다시 읽는다.

Redis 는 그전까지 세션과 캐시만 담당했다. `GET`·`SET` 위주였고
ACL 도 그에 맞춰 구성되어 있었다.

```
user default off
user app on ><password> ~* &* +@read +@write +@connection -@dangerous
```

## 증상

### 1차 — 게이트웨이가 뜨지 않음

```
reused-chat-74f45cbb89-pjjc9   0/1   CrashLoopBackOff   3 (5s ago)   51s
```

로그는 한 줄이었다.

```bash
kubectl -n reused logs reused-chat-74f45cbb89-pjjc9 --previous
```

```
Chat server failed to start (Error)
```

**원인이 보이지 않았다.** 애플리케이션이 `error.name` 만 출력하고 있었다.

```typescript
main().catch((error: unknown) => {
  const name = error instanceof Error ? error.name : "UnknownError";
  console.error(`Chat server failed to start (${name})`);
  process.exitCode = 1;
});
```

일반 `Error` 객체의 `name` 은 `"Error"` 다. `message` 를 찍지 않으면
어떤 에러든 같은 문자열이 나온다.

### 2차 — 기동은 됐는데 실시간이 안 됨

1차를 해결한 뒤 Pod 는 정상이 됐다.

```
reused-chat-647cb567b8-4f7bl   1/1   Running   0   31s
Chat server listening on port 3001
```

**그런데 메시지가 실시간으로 도착하지 않았다.**
다른 창에서 보낸 메시지가 몇 초 뒤에야 나타났다.

애플리케이션 로그는 조용했다. 에러가 없었다.

## 진단 과정

### 1. 환경변수와 Secret 확인 — 정상

```bash
kubectl -n reused get externalsecret reused-chat
# SecretSynced   True

kubectl -n reused get secret reused-chat -o jsonpath='{.data}' \
  | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys()))"
# ['CHAT_REDIS_URL']
```

```bash
kubectl -n reused get secret reused-chat -o jsonpath='{.data.CHAT_REDIS_URL}' \
  | base64 -d | sed -E 's|//app:[^@]*@|//app:***@|'
# redis://app:***@10.20.10.30:6379
```

`config.ts` 의 검증(`new URL()`, 프로토콜 확인)을 통과할 형태였다.

### 2. Redis 연결 확인 — 정상

```bash
kubectl -n reused run redis-test --rm -it --restart=Never --image=redis:7-alpine -- sh
```

```sh
redis-cli -h 10.20.10.30 -p 6379 --user app --askpass ping
# PONG
```

`psubscribe` 도 됐다.

```sh
redis-cli -h 10.20.10.30 -p 6379 --user app --askpass psubscribe 'reused:chat:room:*'
# 1) "psubscribe"
# 2) "reused:chat:room:*"
# 3) (integer) 1
```

URL 인코딩 여부도 양쪽 다 확인했다.

```sh
redis-cli -u "redis://app:XMAee...%2F...%2B...%3D@10.20.10.30:6379" ping   # PONG
redis-cli -u "redis://app:XMAee.../...+...=@10.20.10.30:6379" ping         # PONG
```

**Redis 쪽은 문제가 없어 보였다.**

### 3. 클라이언트가 보내는 명령 확인

`redis-cli` 와 `node-redis` 가 같은 명령을 보내지 않을 수 있다고 보고
라이브러리가 연결 직후 무엇을 하는지 확인했다.

`node-redis` 5.x 는 연결 직후 `CLIENT SETINFO` 로 라이브러리 이름과 버전을
서버에 알린다.

```sh
redis-cli -h 10.20.10.30 -p 6379 --user app --askpass client setinfo lib-name node-redis
```

```
(error) ERR unknown subcommand 'setinfo'. Try CLIENT HELP.
```

**`CLIENT SETINFO` 는 Redis 7.2 에 도입됐다.** 우리는 7.0.15 였다.

`redis-cli` 는 이 명령을 보내지 않으니 잘 붙었던 것이다.

### 4. Redis 8 업그레이드

7.0.15 는 Ubuntu 24.04 universe 저장소의 최신 버전이다.
공식 저장소를 추가해 8.10.2 로 올렸다. 절차는 `docs/09-redis.md` 참조.

업그레이드 중 겪은 것 셋을 기록해 둔다.

| 항목 | 내용 |
| --- | --- |
| **`apt purge` 가 데이터 삭제** | `/etc/redis` 와 **`/var/lib/redis`** 를 함께 지운다 |
| 패키지 이름 | universe 는 `redis-server`, 공식은 `redis`. 섞으면 충돌 |
| **`daemonize`** | Redis 8 유닛은 `Type=notify`. `daemonize yes` 면 기동 실패 |

세 번째는 증상이 헷갈린다. Redis 가 정상 기동한 직후 systemd 가
SIGTERM 을 보낸다.

```
redis-server.service: Failed with result 'protocol'
```

```
* Server initialized
* Ready to accept connections
signal-handler Received SIGTERM scheduling shutdown...
```

`daemonize no` + `supervised systemd` 로 해결했다.

업그레이드 후 확인했다.

```sh
redis-cli -h 10.20.10.30 --user app --askpass client setinfo lib-name node-redis
# OK
```

### 5. 여전히 실패 — 로그를 우회해 원인 추출

`CLIENT SETINFO` 는 해결됐는데 게이트웨이는 그대로 CrashLoop 였다.
메시지는 여전히 `Chat server failed to start (Error)` 뿐이었다.

**애플리케이션을 고치지 않고 원인을 보려면** 같은 이미지로 임시 Pod 를 띄워
`error.message` 까지 출력하는 코드를 실행하면 된다.

```bash
kubectl -n reused run chat-debug --restart=Never \
  --image=794386801311.dkr.ecr.ap-northeast-1.amazonaws.com/logssey/reused-chat:bb4639b7... \
  --overrides='{"spec":{"containers":[{"name":"chat-debug","image":"...",
    "command":["node","-e","Promise.all([import(\"/app/dist/config.js\"),import(\"redis\")])
      .then(async([cfg,redis])=>{const c=cfg.loadConfig();
      const cl=redis.createClient({url:c.redisUrl});
      try{await cl.connect();console.log(\"connected\");
      await cl.pSubscribe(\"reused:chat:room:*\",()=>{});console.log(\"psubscribe ok\");
      await cl.close()}catch(e){console.error(\"FAIL:\",e.name,e.message)}})"],
    "envFrom":[{"configMapRef":{"name":"reused-chat"}},{"secretRef":{"name":"reused-chat"}}]}]}}'
```

```bash
sleep 10 && kubectl -n reused logs chat-debug
```

```
connected
FAIL: Error NOPERM User app has no permissions to run the 'psubscribe' command
```

**원인이 드러났다.**

`-it` 를 붙이면 TTY 할당 실패로 출력이 보이지 않는다.
`--restart=Never` 로 띄우고 `logs` 로 읽는 편이 확실하다.

### 6. 기동 후 — 발행도 막혀 있었다

ACL 에 구독 권한을 추가하니 게이트웨이는 떴다. 그런데 실시간이 안 됐다.

Redis 채널을 직접 구독해 두고 브라우저에서 메시지를 보냈다.

```bash
redis-cli -h 10.20.10.30 --user app --askpass psubscribe 'reused:chat:room:*'
```

**아무것도 오지 않았다.** 발행 자체가 안 되고 있었다.

백엔드 코드에 발행 호출은 있었다.

```bash
grep -n "events\." src/main/java/com/reused/chat/ChatService.java
# 81:  events.afterCommit("message", roomId, message);
# 101: events.afterCommit("read", roomId, ...);
# 112: events.afterCommit("message_deleted", roomId, ...);
```

로그를 좁혀 찾았다.

```bash
kubectl -n reused logs -l app.kubernetes.io/name=reused-api --since=10m \
  | grep -i "Chat event delivery failed"
```

```
WARN  c.reused.chat.ChatEventPublisher : Chat event delivery failed:
  room=4, event=message, cause=RedisSystemException
```

**`PUBLISH` 도 NOPERM 이었다.**

발행 코드가 예외를 삼키고 경고만 남기도록 되어 있었다.

```java
catch (RuntimeException ex) {
    log.warn("Chat event delivery failed: room={}, event={}, cause={}",
        roomId, event, ex.getClass().getSimpleName());
}
```

서비스는 정상 동작했고 프론트의 30초 폴링이 화면을 갱신해
**실시간이 되는 것처럼 보였다.**

## 원인

**ACL 에 pubsub 계열 명령 권한이 없었다.**

```
user app on ><password> ~* &* +@read +@write +@connection -@dangerous
```

`&*` 가 있어 채널 접근은 열려 있었으나, `PUBLISH`·`PSUBSCRIBE` 명령을
실행할 권한이 없었다.

**채널 패턴과 명령 권한은 다른 층위다.**

| 항목 | 통제 대상 |
| --- | --- |
| `&*` | 어떤 채널에 접근해도 되는가 |
| `+@pubsub` | 해당 명령을 실행할 수 있는가 |

문을 열어 두고 들어갈 자격은 주지 않은 셈이다.

캐시와 세션만 쓰던 동안에는 드러나지 않았다.
채팅을 붙이면서 처음 필요해진 권한이다.

### 단정하지 못한 부분

7.0.15 에서 `redis-cli` 로 실행한 `psubscribe` 는 성공했다.
8.10.2 에서 같은 ACL 로 `NOPERM` 이 났다.

두 시점 사이에 패키지 교체와 설정 복원이 있었으므로
**Redis 8 의 동작 변화 때문인지 단정할 수 없다.**

Redis 8 의 ACL 변경 사항은 공식 문서에 정리되어 있으나
`@read`·`@write` 카테고리에 Search·JSON 명령이 **추가**되는 방향이고,
pubsub 권한이 엄격해졌다는 내용은 없다.

8 업그레이드 전 `redis-cli` 로 `publish` 를 시험하지 않은 것이
확인을 어렵게 만들었다. **구독만 테스트하고 발행은 건너뛴 것**이
이 사건에서 가장 아쉬운 지점이다.

## 해결

**파일**: `/etc/redis/acl-users.conf`

```
user default off
user app on ><password> ~* &* +@read +@write +@connection +@pubsub -@dangerous
```

개별 명령(`+psubscribe +punsubscribe +subscribe +unsubscribe`)을 나열하는 대신
**카테고리로 부여했다.** `PUBLISH` 를 빠뜨렸던 것이 2차 증상의 원인이었고,
같은 실수를 반복할 여지를 줄이기 위함이다.

```bash
sudo chown redis:redis /etc/redis/acl-users.conf
sudo chmod 640 /etc/redis/acl-users.conf
sudo cat /etc/redis/acl-users.conf     # 붙여넣기가 깨지기 쉬워 반드시 확인
sudo systemctl restart redis-server
```

애플리케이션 Pod 는 별도로 재시작한다.

```bash
kubectl -n reused rollout restart deployment reused-chat
```

## 검증

**구독과 발행을 모두 확인한다.**

터미널 하나에서 구독한다.

```bash
kubectl -n reused run redis-watch --rm -it --restart=Never --image=redis:8-alpine -- sh
```

```sh
redis-cli -h 10.20.10.30 -p 6379 --user app --askpass psubscribe 'reused:chat:room:*'
```

브라우저에서 메시지를 보냈다.

```
1) "pmessage"
2) "reused:chat:room:*"
3) "reused:chat:room:4"
4) "{\"event\":\"message\",\"chatRoomId\":4,\"data\":{\"messageId\":61,
     \"senderId\":6,\"content\":\"dasdas\",...}}"
1) "pmessage"
...
4) "{\"event\":\"read\",\"chatRoomId\":4,\"data\":{\"readerId\":2,...}}"
```

`message` 와 `read` 이벤트가 즉시 도착했다.

브라우저에서도 실시간 수신을 확인했다.
Network 탭의 `Socket` 필터에 `101 Switching Protocols` 로 연결이 유지된다.

```
socket.io/?EIO=4&transport=websocket   101   websocket   Pending
```

## 재발 방지

**용도가 늘어나면 ACL 을 함께 검토한다.**

최소 권한으로 부여하면 **필요한 카테고리를 빠뜨렸을 때 조용히 실패한다.**
`+@all -@dangerous` 처럼 넓게 주면 이런 일이 없지만 최소 권한 원칙에 어긋난다.

비용을 감수하되 **새 기능을 붙일 때 ACL 을 체크리스트에 넣는다.**

| 용도 | 필요한 카테고리 |
| --- | --- |
| 캐시·세션 | `@read` `@write` |
| Pub/Sub | **`@pubsub`** |
| 모니터링 | `@admin` 일부 (별도 계정 권장) |

**권한 검증은 실제 클라이언트로 한다.**

`redis-cli` 와 애플리케이션 라이브러리는 **같은 명령 시퀀스를 보내지 않는다.**
`redis-cli` 로 되는 것이 애플리케이션에서 안 될 수 있다.

| 도구 | 연결 직후 동작 |
| --- | --- |
| `redis-cli` | `AUTH` 후 사용자 명령만 |
| `node-redis` 5.x | `AUTH` → **`CLIENT SETINFO`** → 사용자 명령 |

이 차이 때문에 초기 진단이 어긋났다.

**읽기·쓰기·구독·발행을 모두 시험한다.**

구독만 확인하고 발행을 건너뛴 탓에 문제를 두 번에 나눠 발견했다.

```bash
# 한쪽에서
redis-cli ... psubscribe 'reused:chat:room:*'
# 다른 쪽에서
redis-cli ... publish 'reused:chat:room:1' 'test'
```

**예외를 삼키는 코드는 관측성이 있어야 안전하다.**

`ChatEventPublisher` 가 발행 실패를 `log.warn` 으로만 처리한 것은
설계 의도로 보인다. 채팅 이벤트 발행이 실패해도 메시지 저장은
성공해야 하기 때문이다.

다만 **그 경고를 아무도 보지 않으면 실패가 묻힌다.**
로그 수집과 경고 규칙이 있었다면 바로 드러났을 문제다.
관측성 스택 도입의 근거로 기록해 둔다.

## 참고

| 항목 | 내용 |
| --- | --- |
| ACL | https://redis.io/docs/latest/operate/oss_and_stack/management/security/acl/ |
| Redis 8 ACL 변경 | https://redis.io/docs/latest/embeds/redis8-breaking-changes-acl |
| `CLIENT SETINFO` | Redis 7.2 도입 |
| `acl-pubsub-default` | 7.0 부터 `resetchannels` 가 기본 |
| Redis 구성 | `docs/09-redis.md` |
| 채팅 게이트웨이 | `service-backend/chat-server/README.md` |
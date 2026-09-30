# 10. 컨테이너 비root 실행 — UID 표기와 이미지의 전제

| 항목 | 내용 |
| --- | --- |
| 발생 | 2026-09-25 (백엔드), 2026-09-28 (프론트) |
| 단계 | Argo CD 배포 |
| 영향 | Pod 기동 불가. 두 서비스가 서로 다른 이유로 막힘 |
| 환경 | Kubernetes 1.35.4, Helm 차트 `reused-api` · `reused-web` |

Helm 차트에 동일한 보안 설정을 넣었는데 두 서비스가 각각 다른 지점에서 실패했다.

```yaml
podSecurityContext:
  runAsNonRoot: true

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

| 서비스 | 실패 지점 |
| --- | --- |
| `reused-api` | 컨테이너 생성 전. kubelet 이 거부 |
| `reused-web` | 컨테이너는 떴으나 nginx 가 기동 실패 |

원인은 다르지만 **"이미지가 무엇을 전제하는가"** 라는 같은 질문으로 수렴한다.

---

## 1차 — 백엔드. 이름으로 쓴 USER

### 증상

ECR 인증 문제를 해결하고(`09-ecr-credential-provider.md`) 이미지는 정상적으로
받아졌는데, 컨테이너가 생성되지 않았다.

```bash
kubectl -n reused describe pod -l app.kubernetes.io/name=reused-api | grep -A10 "Events:"
```

```
Normal   Pulled   20s   kubelet  Successfully pulled image "...:41e0a2fc..."
                                 in 5.447s. Image size: 158777437 bytes.
Warning  Failed   5s (x3 over 20s)  kubelet
  Error: container has runAsNonRoot and image has non-numeric user (app),
  cannot verify user is non-root
```

Pod 는 `CreateContainerConfigError` 상태였다.
이미지를 받는 데는 성공했으니 인증 문제는 해결된 상태였다.

### 원인

Dockerfile 에 사용자를 **이름으로** 지정했다.

```dockerfile
RUN addgroup -S app && adduser -S app -G app
USER app
```

kubelet 은 `runAsNonRoot: true` 를 검증할 때 **이미지 설정의 USER 값을 숫자로 읽는다.**
이름이면 그것이 root 인지 판단할 수 없다. `/etc/passwd` 는 이미지 안에 있고
kubelet 은 컨테이너를 만들기 전이라 그것을 읽을 수 없기 때문이다.

kubelet 소스의 주석이 그대로 말한다.

```go
// Verify RunAsNonRoot. Non-root verification only supports numeric user.
return fmt.Errorf("container has runAsNonRoot and image has non-numeric user (%s), "+
    "cannot verify user is non-root", username)
```

1.9 에서 들어온 동작이다(kubernetes/kubernetes#56503).
그 전에는 경고만 남기고 통과시켰으나, **검증할 수 없는 것을 통과시키면
검증의 의미가 없다**는 이유로 거부로 바뀌었다.

### 해결

먼저 실제 UID 를 확인했다. 추측하면 파일 권한이 어긋난다.

```bash
kubectl -n reused run uid-check --rm -it --restart=Never \
  --image=794386801311.dkr.ecr.ap-northeast-1.amazonaws.com/logssey/reused-api:41e0a2fc... \
  --command -- id
```

```
uid=100(app) gid=101(app) groups=101(app)
```

Alpine 의 `adduser -S` 는 시스템 사용자 범위에서 UID 를 할당한다.
1000 이 아니라 **100** 이었다.

**레포**: `gitops` · `apps/reused-api/values.yaml`

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 100
  runAsGroup: 101
```

이것만으로 Pod 는 뜬다. `runAsUser` 가 있으면 kubelet 은 이미지의 USER 를
보지 않고 그 값을 쓰기 때문이다.

다만 **Dockerfile 도 함께 고쳤다.**

```dockerfile
USER 100:101
```

values 에만 두면 이미지 단독으로 실행할 때(로컬 `docker run`, 다른 오케스트레이터)
여전히 이름으로 동작한다. 두 곳의 값이 어긋날 여지도 남는다.

Hadolint 도 같은 규칙을 둔다(DL3066 — non-numeric user-id may not be resolvable
by host system).

---

## 2차 — 프론트. root 를 전제한 이미지

### 증상

프론트는 UID 문제 없이 컨테이너가 생성됐다. 그런데 곧바로 죽었다.

```
reused-web-76b7bbcc95-4xklz   0/1   CrashLoopBackOff   2 (13s ago)   28s
```

```bash
kubectl -n reused logs reused-web-76b7bbcc95-4xklz --previous --tail=20
```

```
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/09/28 01:47:05 [emerg] 1#1: chown("/var/cache/nginx/client_temp", 101)
  failed (1: Operation not permitted)
nginx: [emerg] chown("/var/cache/nginx/client_temp", 101)
  failed (1: Operation not permitted)
```

진입 스크립트는 끝까지 돌았고, nginx 마스터 프로세스가 캐시 디렉터리
소유권을 바꾸려다 실패했다.

### 원인

**nginx 공식 이미지는 root 로 시작하는 것을 전제한다.**

```
1. root 로 마스터 프로세스 기동
2. 캐시 디렉터리 소유권을 nginx 사용자(101)로 변경  ← 여기
3. 워커 프로세스를 nginx 사용자로 떨어뜨림
4. 80 포트 바인딩 (특권 포트)
```

2번과 3번은 `CHOWN`·`SETUID`·`SETGID`, 4번은 `NET_BIND_SERVICE` capability 를
요구한다. 우리는 전부 제거했다.

```yaml
capabilities:
  drop:
    - ALL
```

**`capabilities.drop: [ALL]` 은 root 로 뜨는 것 자체를 막지 않는다.**
root 이되 아무 권한도 없는 상태가 된다. 그래서 진입 스크립트는 돌고
chown 에서 멈춘 것이다.

### 대안 검토

| 안 | 내용 |
| --- | --- |
| A. 필요한 capability 를 되돌림 | `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE` 추가 |
| **B. 비root 이미지로 교체** | `nginxinc/nginx-unprivileged` |

A 는 한 줄이면 끝나지만 **문제를 설정으로 덮는다.** 이미지가 여전히 root 로
시작하고, 권한을 되돌린 만큼 `drop: [ALL]` 의 의미가 줄어든다.

B 는 Dockerfile 과 포트를 고쳐야 하지만 **이미지 자체가 비root 를 전제**한다.
캐시 디렉터리 소유권이 빌드 시점에 이미 맞춰져 있어 chown 이 필요 없다.

파이프라인 검증 단계였고 프론트 이미지를 최적화하지 않은 상태이기도 해서
**B 를 택했다.**

### 해결

UID 부터 확인했다. 1차에서 배운 것을 그대로 적용했다.

```bash
docker run --rm nginxinc/nginx-unprivileged:1.30-alpine id
```

```
uid=101(nginx) gid=101(nginx) groups=101(nginx)
```

**Dockerfile**

```dockerfile
# nginx 공식 이미지는 root 로 시작해 캐시 디렉터리 소유권을 바꾼 뒤
# 워커를 nginx 사용자로 떨어뜨린다. Pod 에서 capabilities 를 제거하면
# 그 chown 이 실패한다.
#
# unprivileged 이미지는 처음부터 비root(UID 101)로 동작하도록
# 디렉터리 권한과 설정 경로가 조정되어 있다.
# 특권 포트를 쓸 수 없으므로 80 대신 8080 을 연다.
FROM nginxinc/nginx-unprivileged:1.30-alpine

# 기본 설정을 지우고 SPA 용 설정으로 교체한다.
# 이미지가 비root 로 실행되므로 COPY 단계에서만 root 권한이 있다.
USER root
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/ /usr/share/nginx/html/
USER 101

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
```

**빌드 중에만 root 로 올린다.** 기본 USER 가 101 이라 그 상태로는
`/etc/nginx/conf.d/` 에 쓸 수 없다. 빌드 시점의 USER 와 런타임 USER 는
별개이므로 마지막에 101 로 되돌리면 실행은 비root 다.

**nginx.conf**

```nginx
server {
    # unprivileged 이미지는 비root 로 동작해 1024 미만 포트를 열 수 없다.
    listen 8080;
    ...
}
```

**gitops · `apps/reused-web/values.yaml`**

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 101
  runAsGroup: 101

securityContext:
  allowPrivilegeEscalation: false
  # unprivileged 이미지는 chown 이나 setuid 를 하지 않으므로
  # 모든 capability 를 제거해도 동작한다.
  capabilities:
    drop:
      - ALL

service:
  type: ClusterIP
  port: 8080
```

### 로컬 검증

클러스터에 올리기 전에 확인했다. CI 한 바퀴가 몇 분 걸리기 때문이다.

```bash
npm run build
docker build -t test-web-unpriv .
docker run --rm -d --name web-test -p 8081:8080 test-web-unpriv
```

```bash
curl -sI http://localhost:8081/ | head -3
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/products/123
```

```
HTTP/1.1 200 OK
Server: nginx/1.30.5
200
```

두 번째는 SPA 라우팅 확인이다. `/products/123` 에 대응하는 파일이 없어도
`try_files` 가 `index.html` 을 반환해야 한다.

---

## 교훈

**`runAsNonRoot: true` 는 선언이 아니라 검증 요구다.**

kubelet 이 확인할 수 있는 형태로 정보를 줘야 한다. 숫자 UID 가 그것이다.
"비root 로 만들었다"는 개발자의 의도는 검증 대상이 아니다.

**`capabilities.drop: [ALL]` 은 이미지가 그 전제를 받아들일 때만 유효하다.**

권한을 제거한다고 프로세스가 비root 가 되지는 않는다. root 로 뜨되
할 수 있는 일이 없어지는 것이고, root 를 전제한 이미지는 그 상태에서 실패한다.

두 사건 모두 **Helm values 만 보고는 알 수 없었다.** 설정은 올바랐고
이미지가 그 설정과 맞지 않았을 뿐이다.

---

## 재발 방지

**새 이미지를 도입하면 UID 를 먼저 확인한다.**

```bash
docker run --rm <image> id
```

한 줄이면 끝난다. 값을 모른 채 `runAsUser` 를 추측하면 Pod 가 뜨더라도
파일 권한에서 다시 막힌다.

**Dockerfile 의 USER 는 숫자로 쓴다.**

| 표기 | 결과 |
| --- | --- |
| `USER app` | kubelet 이 검증 불가 |
| **`USER 100:101`** | **검증 가능** |

**비root 를 요구하면 비root 이미지를 고른다.**

| 이미지 | 전제 |
| --- | --- |
| `nginx` | root 로 시작 |
| **`nginxinc/nginx-unprivileged`** | **비root, 8080 포트** |
| `node:*-alpine` | `node` 사용자 UID 1000 존재. USER 는 직접 지정 |

공식 이미지가 항상 제약 환경에 맞는 것은 아니다.
벤더가 별도로 비root 변종을 제공하는지 먼저 확인한다.

**로컬에서 컨테이너를 띄워본 뒤 CI 에 올린다.**

`docker run` 한 번이면 드러날 문제로 파이프라인을 여러 번 돌렸다.
특히 이미지 교체처럼 실행 환경이 바뀌는 변경에서는 로컬 검증이 빠르다.

---

## 참고

| 항목 | 내용 |
| --- | --- |
| 비숫자 USER 거부 | kubernetes/kubernetes#56503 |
| Pod Security Standards | https://kubernetes.io/docs/concepts/security/pod-security-standards/ |
| SecurityContext | https://kubernetes.io/docs/tasks/configure-pod-container/security-context/ |
| Hadolint DL3066 | non-numeric user-id may not be resolvable by host system |
| nginx-unprivileged | https://github.com/nginx/docker-nginx-unprivileged |
| 선행 문제 | `docs/troubleshooting/09-ecr-credential-provider.md` |
| 차트 구성 | `docs/11-cicd.md` |
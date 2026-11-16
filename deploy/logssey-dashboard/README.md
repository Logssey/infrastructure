# Logssey 대시보드 (전용 EC2)

결정과 이유: dashboard-design-docs ADR-D010. Terraform: terraform/environments/logssey-dashboard.

- 접속: https://logssey.re-used.store (ALB → frontend :8088). GitHub 로그인, Logssey 조직의 활성 멤버만 들어온다. 처음 로그인하면 ADMIN 계정이 생긴다
- 비상 접속: aws ssm start-session --target <instance_id> --document-name AWS-StartPortForwardingSession --parameters 'portNumber=["8088"],localPortNumber=["8088"]' 후 http://localhost:8088, 비밀번호 admin
- 호스트 파일: /opt/logssey (compose.yaml, api.properties, worker.properties, initdb/, .env, secrets/). 비밀값 파일은 저장소에 올리지 않는다
  - GitHub OAuth App client secret: secrets/api/spring.security.oauth2.client.registration.github.client-secret (소유 10001, 0400)
  - Reach 스캔 요청 GitHub App 개인 키: secrets/api/logssey.reach.dispatch.private-key (GitHub 이 준 .pem 그대로, 소유 10001, 0400). 키가 잘못되면 API 가 뜨지 않는다
  - Secret 워커 DB 비밀번호: secrets/worker/spring.datasource.password (API 와 같은 값, 소유 10001, 0400). 수집을 켜면 Secret 담당이 정한 파일(Notion 토큰, 지문 키 등)을 같은 폴더에 둔다
  - Notion 페이지 검사: Notion 연동 토큰 secrets/worker/notion-token 과 secrets/api/notion-token(API 는 연결 테스트용), 지문 키 secrets/worker/logssey.secret.detection.fingerprint-key(32바이트 이상 난수의 base64, 버전은 worker.properties). 모두 소유 10001, 0400. 지문 키·버전은 결과가 생긴 뒤 바꾸지 않는다(같은 키가 새 키로 보인다)
  - Notion 검사 대상: 연결 `notion-internal:default` 한 줄(secret_connections)과 페이지마다 범위 한 줄(secret_connection_scopes, `notion://pages/<id>`). 등록 화면이 없어 SQL 로 넣는다. 범위는 그 페이지 본문만이고 하위 페이지는 따로 넣는다. 연동이 공유받지 않은 페이지는 NOTION_ACCESS_DENIED
- Secret 워커(secret-worker): dashboard-backend 의 secret-worker 를 API 와 같은 커밋으로 띄운다. 웹 포트 없이 DB 와 승인된 수집 대상만 본다. worker.properties 는 처음에 예약·실행·수집을 모두 끈다. 켜는 것은 Secret 담당이 정해 이 레포 PR 로 바꾼다
- 업데이트(자동): dashboard-backend·dashboard-frontend 의 develop 에 머지되면 각 레포의 `Dashboard deploy` 워크플로가 테스트 → 이미지 push → SSM 문서 `logssey-dashboard-deploy` 로 호스트의 `/opt/logssey/deploy.sh api|frontend|worker <digest>` 를 부른다 (terraform deploy.tf). dashboard-backend 는 API 를 배포한 뒤 같은 커밋의 워커를 배포한다(레포 변수 `DASHBOARD_DEPLOY_WORKER=true` 일 때)
  - deploy.sh: (api 만) DB 덤프 `/var/lib/logssey/backups/` 최근 5개 → .env digest 교체 → pull·재생성(api 면 nginx 도 재시작) → 상태 확인 → 안 되면 이전 digest 로 되돌리고 실패. 기록은 `/opt/logssey/deploy.log`
  - 상태 확인: api·frontend 는 5분 안에 화면과 API 가 응답. worker 는 60초 뒤 재시작 없이 돌고 있고 그 사이 DB 에 heartbeat(`secret_worker_heartbeats`)를 남겼는지
  - 호스트에 둘 때: 이 폴더의 deploy.sh 를 `/opt/logssey/deploy.sh` 로, root 소유 0500
  - 손으로 배포: 같은 명령을 root 로 `/opt/logssey/deploy.sh api sha256:…`
  - 바뀌지 않는 것: compose.yaml·api.properties·worker.properties 는 이 레포에서 고쳐 머지한 뒤 호스트에 손으로 덮어쓴다
- DB 되돌리기(새 마이그레이션이 적용된 뒤 옛 API 로 돌아가야 할 때): `docker compose stop api frontend secret-worker` → `docker compose exec -T db dropdb -U postgres logssey` → `docker compose exec -T db createdb -U postgres -O logssey logssey` → `docker compose exec -T db pg_restore -U postgres -d logssey --no-owner --role=logssey < /var/lib/logssey/backups/<덤프>` → .env 를 옛 digest 로 → `docker compose up -d`
- DB 데이터: /var/lib/logssey (따로 붙인 EBS, 매일 스냅샷 7개)
- 다른 서비스에 설치: variables.tf 의 VPC·서브넷 이름·service_domain·dashboard_host, api.properties 의 logssey.reach.*·GitHub 설정(client-id, redirect-uri, allowed-organization)만 바꾼다 (ADR-D009)

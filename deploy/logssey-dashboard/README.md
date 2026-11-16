# Logssey 대시보드 (전용 EC2)

결정과 이유: dashboard-design-docs ADR-D010. Terraform: terraform/environments/logssey-dashboard.

- 접속: https://logssey.re-used.store (ALB → frontend :8088). GitHub 로그인, Logssey 조직의 활성 멤버만 들어온다. 처음 로그인하면 ADMIN 계정이 생긴다
- 비상 접속: aws ssm start-session --target <instance_id> --document-name AWS-StartPortForwardingSession --parameters 'portNumber=["8088"],localPortNumber=["8088"]' 후 http://localhost:8088, 비밀번호 admin
- 호스트 파일: /opt/logssey (compose.yaml, api.properties, initdb/, .env, secrets/). 비밀값 파일은 저장소에 올리지 않는다
  - GitHub OAuth App client secret: secrets/api/spring.security.oauth2.client.registration.github.client-secret (소유 10001, 0400)
- 업데이트(자동): dashboard-backend·dashboard-frontend 의 develop 에 머지되면 각 레포의 `Dashboard deploy` 워크플로가 테스트 → 이미지 push → SSM 문서 `logssey-dashboard-deploy` 로 호스트의 `/opt/logssey/deploy.sh api|frontend <digest>` 를 부른다 (terraform deploy.tf)
  - deploy.sh: (api 만) DB 덤프 `/var/lib/logssey/backups/` 최근 5개 → .env digest 교체 → pull·재생성(api 면 nginx 도 재시작) → 화면·API 상태 확인 → 5분 안에 안 뜨면 이전 digest 로 되돌리고 실패. 기록은 `/opt/logssey/deploy.log`
  - 호스트에 둘 때: 이 폴더의 deploy.sh 를 `/opt/logssey/deploy.sh` 로, root 소유 0500
  - 손으로 배포: 같은 명령을 root 로 `/opt/logssey/deploy.sh api sha256:…`
  - 바뀌지 않는 것: compose.yaml·api.properties 는 이 레포에서 고쳐 머지한 뒤 호스트에 손으로 덮어쓴다
- DB 되돌리기(새 마이그레이션이 적용된 뒤 옛 API 로 돌아가야 할 때): `docker compose stop api frontend` → `docker compose exec -T db dropdb -U postgres logssey` → `docker compose exec -T db createdb -U postgres -O logssey logssey` → `docker compose exec -T db pg_restore -U postgres -d logssey --no-owner --role=logssey < /var/lib/logssey/backups/<덤프>` → .env 를 옛 digest 로 → `docker compose up -d`
- DB 데이터: /var/lib/logssey (따로 붙인 EBS, 매일 스냅샷 7개)
- 다른 서비스에 설치: variables.tf 의 VPC·서브넷 이름·service_domain·dashboard_host, api.properties 의 logssey.reach.*·GitHub 설정(client-id, redirect-uri, allowed-organization)만 바꾼다 (ADR-D009)

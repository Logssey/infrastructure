# Logssey 대시보드 (전용 EC2)

결정과 이유: dashboard-design-docs ADR-D010. Terraform: terraform/environments/logssey-dashboard.

- 접속: https://logssey.re-used.store (ALB → frontend :8088). GitHub 로그인, Logssey 조직의 활성 멤버만 들어온다. 처음 로그인하면 ADMIN 계정이 생긴다
- 비상 접속: aws ssm start-session --target <instance_id> --document-name AWS-StartPortForwardingSession --parameters 'portNumber=["8088"],localPortNumber=["8088"]' 후 http://localhost:8088, 비밀번호 admin
- 호스트 파일: /opt/logssey (compose.yaml, api.properties, initdb/, .env, secrets/). 비밀값 파일은 저장소에 올리지 않는다
  - GitHub OAuth App client secret: secrets/api/spring.security.oauth2.client.registration.github.client-secret (소유 10001, 0400)
- 업데이트: 새 이미지를 push → /opt/logssey/.env 의 digest 를 바꿈 → docker compose up -d
- DB 데이터: /var/lib/logssey (따로 붙인 EBS, 매일 스냅샷 7개)
- 다른 서비스에 설치: variables.tf 의 VPC·서브넷 이름·service_domain·dashboard_host, api.properties 의 logssey.reach.*·GitHub 설정(client-id, redirect-uri, allowed-organization)만 바꾼다 (ADR-D009)

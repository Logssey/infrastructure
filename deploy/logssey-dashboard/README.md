# Logssey 대시보드 (전용 EC2)

결정과 이유: dashboard-design-docs ADR-D010. Terraform: terraform/environments/logssey-dashboard.

- 접속: aws ssm start-session --target <instance_id> --document-name AWS-StartPortForwardingSession --parameters 'portNumber=["8088"],localPortNumber=["8088"]' 후 http://localhost:8088
- 호스트 파일: /opt/logssey (compose.yaml, api.properties, initdb/, .env, secrets/). 비밀값 파일은 저장소에 올리지 않는다
- 업데이트: 새 이미지를 push → /opt/logssey/.env 의 digest 를 바꿈 → docker compose up -d
- DB 데이터: /var/lib/logssey (따로 붙인 EBS, 매일 스냅샷 7개)
- 다른 서비스에 설치: variables.tf 의 VPC·서브넷 이름, api.properties 의 logssey.reach.* 만 바꾼다 (ADR-D009)
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
- Secret 워커(secret-worker): dashboard-backend 의 secret-worker 를 API 와 같은 커밋으로 띄운다. DB 작업을 받아 승인된 대상에 접근한다. GitHub·AWS 연결은 대시보드에서 등록하고, 예약은 6시간 주기다. AWS는 IAM·도쿄 리전 Secrets Manager·Parameter Store·S3 버킷 목록 메타데이터를 수집한다
- 업데이트(자동): dashboard-backend·dashboard-frontend 의 develop 에 머지되면 각 레포의 `Dashboard deploy` 워크플로가 테스트 → 이미지 push → SSM 문서 `logssey-dashboard-deploy` 로 호스트의 `/opt/logssey/deploy.sh api|frontend|worker <digest>` 를 부른다 (terraform deploy.tf). dashboard-backend 는 API 를 배포한 뒤 같은 커밋의 워커를 배포한다(레포 변수 `DASHBOARD_DEPLOY_WORKER=true` 일 때)
  - deploy.sh: (api 만) DB 덤프 `/var/lib/logssey/backups/` 최근 5개 → .env digest 교체 → pull·재생성(api 면 nginx 도 재시작) → 상태 확인 → 안 되면 이전 digest 로 되돌리고 실패. 기록은 `/opt/logssey/deploy.log`
  - 상태 확인: api·frontend 는 5분 안에 화면과 API 가 응답. worker 는 60초 뒤 재시작 없이 돌고 있고 그 사이 DB 에 heartbeat(`secret_worker_heartbeats`)를 남겼는지
  - 호스트에 둘 때: 이 폴더의 deploy.sh 를 `/opt/logssey/deploy.sh` 로, root 소유 0500
  - 손으로 배포: 같은 명령을 root 로 `/opt/logssey/deploy.sh api sha256:…`
  - 바뀌지 않는 것: compose.yaml·api.properties·worker.properties 는 이 레포에서 고쳐 머지한 뒤 호스트에 손으로 덮어쓴다
- DB 되돌리기(새 마이그레이션이 적용된 뒤 옛 API 로 돌아가야 할 때): `docker compose stop api frontend secret-worker` → `docker compose exec -T db dropdb -U postgres logssey` → `docker compose exec -T db createdb -U postgres -O logssey logssey` → `docker compose exec -T db pg_restore -U postgres -d logssey --no-owner --role=logssey < /var/lib/logssey/backups/<덤프>` → .env 를 옛 digest 로 → `docker compose up -d`
- DB 데이터: /var/lib/logssey (따로 붙인 EBS, 매일 스냅샷 7개)
- 다른 서비스에 설치: variables.tf 의 VPC·서브넷 이름·service_domain·dashboard_host와 api.properties 의 logssey.reach.*·GitHub 로그인 설정을 맞춘다. API·워커의 연결 관리 계정·리전·비밀 경로는 Terraform의 source_credentials_config·source_secret_prefix 출력과 맞춘다 (ADR-D009)

## GitHub·AWS 연결 관리

연결 관리 화면에서 GitHub App 인증정보와 검사할 저장소·브랜치·폴더를 등록한다. 개인키는 `logssey/dashboard/source-credentials/` 아래 Secrets Manager에 저장하고, DB는 참조 ARN과 버전·대상·변경 이력을 보존한다. 저장된 개인키는 교체·삭제할 수 있다. GitHub App 설치의 허용 저장소 목록은 GitHub에서 관리한다.

AWS는 이 계정의 워크로드 역할을 사용한다. API와 워커는 각각 `logssey-dashboard-role-secret-api`, `logssey-dashboard-role-secret-worker`의 단기 세션을 사용한다. API 역할은 지정한 연결 비밀 경로의 생성·조회·교체·삭제 권한을 갖고, 워커는 조회 권한을 갖는다. 두 역할의 자산 수집 권한은 메타데이터 조회에 한정한다. 호스트의 IMDSv2 hop limit은 1을 유지한다.

### 단기 AWS 세션 공급

Terraform의 `source-credentials.tf`를 적용한 뒤 `terraform output -json source_credentials_config` 결과를 호스트의 `/opt/logssey/source-credentials.json`에 root 소유 0600으로 둔다. `source-credentials.example.json`은 형식 예시다. 설정에는 역할 ARN과 리전이 들어간다.

호스트에서 아래 파일을 설치한다. 배포 폴더에 있는 파일을 현재 디렉터리로 복사한 상태에서 실행한다.

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends python3-boto3
sudo install -d -o root -g root -m 0700 /opt/logssey/aws
sudo install -o root -g root -m 0500 publish-aws-credentials.py /opt/logssey/
sudo install -o root -g root -m 0644 logssey-source-credentials.service /etc/systemd/system/
sudo install -o root -g root -m 0644 logssey-source-credentials.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start logssey-source-credentials.service
sudo systemctl enable --now logssey-source-credentials.timer
sudo systemctl status logssey-source-credentials.service
```

호스트 역할이 두 애플리케이션 역할을 AssumeRole하여 1시간짜리 세션을 발급하고, 타이머가 10분마다 갱신한다. 결과는 `aws/api/credentials.json`, `aws/worker/credentials.json`에 UID 10001만 읽도록 원자적으로 교체한다. 각 컨테이너는 자기 디렉터리를 `/run/aws`에 읽기 전용으로 마운트한다. 갱신 실패 시 이전 파일을 보존하며 systemd 실패 상태로 기록한다. 앱은 파일의 세션 만료를 확인하고 갱신된 파일을 다시 읽는다.

### 설정 반영과 확인

연결 관리 API와 세션 파일 인증을 지원하는 백엔드 이미지를 먼저 배포한다. 현재 폴더의 `compose.yaml`, `api.properties`, `worker.properties`를 호스트에 반영하고 컨테이너를 재생성한다. 설정 교체는 보호 디렉터리의 백업과 함께 수행한다.

AWS 메타데이터 식별 키 `secrets/worker/logssey.secret.aws.collection.identity-key`에는 32바이트 이상 난수의 Base64를 개행 없이 저장한다. UID 10001, 모드 0400이며 버전은 `worker.properties`의 `v1`과 맞춘다. 기존 콘텐츠 지문 키와 각 키의 버전은 지속적으로 보존한다.

```bash
cd /opt/logssey
sudo docker compose up -d --force-recreate api secret-worker
sudo docker compose restart frontend
sudo systemctl list-timers logssey-source-credentials.timer
```

로그인 계정에 Secret의 OPERATIONS 역할을 부여하고 연결 관리에서 연결 테스트와 수동 스캔을 확인한다. 최초 스캔 결과와 워커 heartbeat를 확인한 뒤 정기 실행 시간을 점검한다. 설정 복구가 필요하면 보호한 설정 백업을 되돌리고 해당 컨테이너를 재생성한다. 역할 세션 갱신 오류는 `journalctl -u logssey-source-credentials.service`에서 확인하며 자격 증명 값은 로그에 기록하지 않는다.

### Claude API 자격 증명

Claude API 키는 `logssey/dashboard/ai/claude-api-key`라는 Secrets Manager 비밀의 문자열 값으로 관리한다. `api.properties`에는 비밀 이름과 리전을 설정한다. 대시보드 API는 `/run/aws/credentials.json`의 단기 API 역할 세션으로 값을 읽는다. 키 교체는 같은 비밀의 현재 버전을 갱신한다.

`claude-api.tf`는 비밀 메타데이터를 참조하고 API 역할에 해당 비밀의 `GetSecretValue`, `DescribeSecret` 권한을 부여한다. 비밀을 먼저 생성한 뒤 Terraform을 적용한다. 키 값은 Terraform 입력이나 상태 파일에 넣지 않는다. 워커의 연결 비밀 조회 권한은 기존 source-credentials 경로를 사용한다.

새 설정은 Secrets Manager 참조를 지원하는 API 이미지를 배포한 뒤 호스트의 `api.properties`에 반영한다. Claude 준비 상태와 합성 자료 기반 안내 요청, 제공자 오류 시 기본 안내 사용을 확인한다.

### 로컬 검증

```bash
python3 -m unittest discover -s deploy/logssey-dashboard -p test_publish_aws_credentials.py
terraform -chdir=terraform/environments/logssey-dashboard fmt -check
```

## IaC 보안 워커 (IaC 보안 ADR-13)

IaC 워커(`iac-worker`)는 그래프 보강, PR 경로 분석, State·드리프트 점검을 한다. 웹 포트가 없고, DB는 IaC 전용 계정 `logssey_iac`(IaC 테이블별 최소 권한)로, AWS는 읽기 전용 역할(`logssey-dashboard-role-iac-worker`: CloudFront 배포 목록, IAM 시뮬레이터)로만 쓴다.

- 호스트의 `compose.yaml`·`deploy.sh`는 덮어쓰지 않는다. Compliance 워커처럼 다른 솔루션이 호스트 파일을 직접 고쳐 두었으므로, `bootstrap-iac-host.py`가 IaC 부분만 더한다(백업을 남기고, 다시 돌려도 바뀌지 않음)
- `iac-worker` 서비스는 compose profile `iac`라서 `docker compose up -d`로는 뜨지 않는다. `deploy.sh iac-worker <digest>`만 띄운다
- AWS 세션은 Secret과 같은 방식(호스트 역할 → 1시간 세션 파일, 10분마다 갱신)이지만 IaC 전용 스크립트·타이머(`publish-iac-credentials.py`, `logssey-iac-credentials.timer`)를 쓴다. 세션 이름은 `logssey-iac-worker`. 컨테이너는 `credential_process`(`iac-worker.aws-config`)로 파일을 읽는다

**처음 한 번 (순서대로)**

1. Terraform 적용: `terraform/environments/logssey-dashboard` (ECR `logssey/dashboard-iac-worker`, IaC 워커 역할, 배포 역할·SSM 문서에 `iac-worker` 추가). plan에서 SSM 문서의 `allowedValues`가 지금 호스트에서 쓰는 값을 지우지 않는지 확인한다
2. 이 폴더의 IaC 파일을 호스트 `/opt/logssey`에 복사: `iac-worker.properties`, `iac-worker.aws-config`, `publish-iac-credentials.py`, `iac-db-role.sh`, `bootstrap-iac-host.py`, `logssey-iac-credentials.service`, `logssey-iac-credentials.timer`
3. `iac-credentials.json`: `iac-credentials.example.json`을 복사하고 `worker_role_arn`을 Terraform 출력 `iac_worker_role_arn`으로 맞춘다
4. DB 비밀번호: `secrets/iac-worker/spring.datasource.password`에 무작위 값(개행 없이), 폴더·파일 소유 10001, 폴더 0500·파일 0400
5. `sudo python3 bootstrap-iac-host.py` → `compose.yaml`·`deploy.sh`·`.env`에 IaC 부분 추가 (`.env`에는 `IAC_WORKER_IMAGE` 자리표시 값)
6. `sudo ./iac-db-role.sh` → `logssey_iac` 계정과 권한 (API가 IaC 마이그레이션 V11·V12를 적용한 뒤)
7. 세션 타이머: `sudo cp logssey-iac-credentials.* /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now logssey-iac-credentials.timer` → `aws-iac/worker/credentials.json` 생기는지 확인
8. dashboard-backend 레포 변수 `DASHBOARD_DEPLOY_IAC_WORKER=true` → 다음 develop 머지(또는 `Dashboard deploy` 다시 실행)에서 워커가 배포된다. 실패하면 처음 배포는 워커만 지우고 다른 서비스는 그대로 둔다

**확인**: `sudo docker compose ps iac-worker`가 재시작 없이 돈다. 자산 그래프(Neo4j)를 붙이기 전에는 그래프·분석 작업이 대기 상태로 남는다(오류 아님).

**IaC 테이블을 새로 만들 때**: `iac-db-role.sh`에 GRANT를 더하고 호스트에서 다시 실행한다.

```bash
python3 -m unittest discover -s deploy/logssey-dashboard -p 'test_*iac*.py'
```

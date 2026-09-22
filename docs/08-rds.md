# 08. RDS PostgreSQL

## 참고 문서

| 항목 | 링크 |
| --- | --- |
| RDS 보안 베스트 프랙티스 | https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.Security.html |
| PostgreSQL 보안 백서 | https://d1.awsstatic.com/Amazon%20Aurora%20PostgreSQL%20and%20Amazon%20RDS%20for%20PostgreSQL%20Security%20Whitepaper.pdf |
| SSL 연결 | https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html |
| 마스터 비밀번호 관리 | https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html |
| 파라미터 그룹 | https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithDBInstanceParamGroups.html |

---

## 구성

| 항목 | 값 |
| --- | --- |
| 엔진 | PostgreSQL 18.6 |
| 인스턴스 클래스 | db.t4g.small |
| 스토리지 | gp3 20GB (오토스케일링 상한 100GB) |
| 배치 | Private-Data ×3 (Subnet Group) |
| Multi-AZ | 비활성 |
| SG | sg-rds |
| DB 이름 | reused |
| 마스터 사용자 | logssey_admin |

### 엔진 버전

조회 시점(2026-09) 기준 최신인 **18.6 을 선택했다.**

PostgreSQL 18 은 2025년 9월 25일 릴리스되어 1년이 지났고 마이너가 6회 누적되었다.
RDS 도 18.1 부터 18.6 까지 제공하고 있어 AWS 검증을 거친 상태다.

18 의 주요 변경은 아래와 같다.

| 항목 | 내용 |
| --- | --- |
| 비동기 I/O (AIO) | sequential scan, bitmap heap scan, vacuum 성능 개선 |
| skip scan | 다중 컬럼 B-tree 인덱스를 더 많은 경우에 활용 |
| Virtual generated columns | 읽기 시점 계산. generated column 의 새 기본값 |
| Temporal constraints | 범위에 대한 PK, UNIQUE, FK |
| RETURNING 의 OLD/NEW | INSERT, UPDATE, DELETE, MERGE |

호환성 변경 사항은 **대부분 업그레이드 시나리오에 해당한다.**

| 항목 | 신규 구축 영향 |
| --- | --- |
| initdb 기본 data checksums 활성화 | 없음. 저장 손상 탐지가 기본으로 켜져 이득 |
| 시간대 약어 처리 변경 | 세션 시간대를 우선 참조. 영향 미미 |
| ICU collation 의 full-text search·pg_trgm | 업그레이드 시 reindex 권장. 신규 생성은 무관 |

**드라이버 호환성은 백엔드 작업 시 확인한다.**
PostgreSQL JDBC 드라이버는 하위 호환되나 새 메이저에서
동작이 달라지는 경우가 있다.

```bash
aws rds describe-db-engine-versions \
  --engine postgres --region ap-northeast-1 \
  --query 'DBEngineVersions[].EngineVersion' --output text \
  | tr '\t' '\n' | sort -V | tail -10

aws rds describe-orderable-db-instance-options \
  --engine postgres --engine-version 18.6 \
  --db-instance-class db.t4g.small --region ap-northeast-1 \
  --query 'OrderableDBInstanceOptions[0].[DBInstanceClass,SupportsPerformanceInsights,SupportsStorageAutoscaling]' \
  --output table
```

**RDS 버전 표기** — 콘솔에는 `18.6-R1` 처럼 리비전이 붙는다.
`-R1`, `-R2` 는 AWS 가 같은 커뮤니티 버전에 자체 패치를 적용한 빌드 번호다.
Terraform 에는 `18.6` 만 지정하면 해당 마이너의 최신 리비전이 적용된다.

### 인스턴스 클래스

| 클래스 | vCPU | 메모리 | 최대 연결 수 | 월 비용 (도쿄) |
| --- | --- | --- | --- | --- |
| db.t4g.micro | 2 | 1 GiB | 약 112 | 약 $15 |
| **db.t4g.small** | 2 | 2 GiB | 약 225 | 약 $30 |

`max_connections` 기본값은 메모리 기반으로 계산된다.
(`LEAST({DBInstanceClassMemory/9531392}, 5000)`)

micro 로도 동작하나 **커넥션 풀 관리에 여유가 없다.**
Spring Boot HikariCP 기본 풀 크기가 10 이므로 Pod 10개면 100 연결이다.
small 은 여유가 있고, 인스턴스 클래스 변경은 재시작(수 분 다운타임)만으로 가능하다.

### Multi-AZ 미적용

비용이 2배가 된다. 실 트래픽이 없는 단계에서 감수한다.

| 항목 | 내용 |
| --- | --- |
| 장애 영향 | AZ 장애 시 DB 접근 불가. 수동 복구 필요 |
| 전환 방법 | `multi_az = true` 로 변경 후 apply. 다운타임 없음 |
| 검토 시점 | 실 트래픽 발생 또는 가용성 요구 발생 시 |

Subnet Group 에는 **AZ 3개를 모두 등록한다.**
RDS 는 최소 2개 AZ 를 요구하며, Multi-AZ 전환 시 Subnet Group 을
수정하지 않아도 되도록 미리 넣어둔다. 사용하지 않는 서브넷에 비용은 없다.

`availability_zone` 은 지정하지 않는다. 지정하면 해당 AZ 장애 시
복구 선택지가 줄어든다.

---

## 보안

### 네트워크 격리

| 계층 | 조치 |
| --- | --- |
| 서브넷 | Private-Data. 인터넷 기본 경로 없음 |
| `publicly_accessible` | false |
| SG | sg-worker 출발 5432 만 허용 (strict 모드) |

Private-Data 라우팅 테이블에는 `0.0.0.0/0` 경로가 없다.
RDS 가 외부로 나가는 경로도, 외부에서 도달하는 경로도 존재하지 않는다.

`docs/01-network.md` 와 `docs/02-security.md` 참조.

### 저장 암호화

`storage_encrypted = true`, 기본 KMS 키를 사용한다.

**생성 시점에만 설정할 수 있다.** 사후 적용하려면
스냅샷 → 암호화 복사 → 새 인스턴스로 교체해야 한다.
`docs/04-compute.md` 의 EBS 암호화와 같은 이유로 1차부터 활성화한다.

자동 스냅샷은 인스턴스의 암호화 설정을 상속한다.

### 전송 암호화 — rds.force_ssl

파라미터 그룹에 `rds.force_ssl = 1` 을 설정한다.

이 값이 1 이면 **SSL 을 사용하지 않는 연결이 거부된다.**
기본값 0 에서는 평문 연결이 가능하며, 애플리케이션이 SSL 을 쓰지 않아도
연결이 성립해 문제를 인지하지 못한다.

애플리케이션은 JDBC URL 에 SSL 옵션을 명시해야 한다.

```
jdbc:postgresql://<endpoint>:5432/reused?sslmode=require
```

`sslmode=verify-full` 로 인증서 검증까지 하려면 RDS CA 번들이 필요하다.
VPC 내부 통신이므로 1차 구축에서는 `require` 로 충분하다.

### 비밀번호 관리

**`manage_master_user_password = true`** 를 사용한다.

AWS 가 비밀번호를 생성해 Secrets Manager 에 저장하며,
**Terraform 은 비밀번호 값을 알지 못한다.**

| 방식 | tfstate 평문 | 비용 |
| --- | --- | --- |
| `password` 인자 직접 지정 | 남음 | 무료 |
| `random_password` + Parameter Store | 남음 | 무료 |
| **`manage_master_user_password`** | **안 남음** | 시크릿당 월 $0.40 |

Terraform 이 값을 아는 순간 상태 파일에 기록된다.
data source 로 읽어도 마찬가지다. 평문을 없애는 유일한 방법이 AWS 관리형이다.

AWS 보안 백서도 자격증명을 코드나 설정 파일에 평문으로 두는 것을
중대한 위험으로 보고 Secrets Manager 사용을 권장한다.

시크릿 ARN 은 아래로 참조한다.

```hcl
aws_db_instance.main.master_user_secret[0].secret_arn
```

`password` 와 `manage_master_user_password` 는 상호 배타적이다.
기존 인스턴스를 전환하려면 `password` 속성을 먼저 제거해야 한다.

**스냅샷 복원 시 주의** — `snapshot_identifier` 와 함께 쓰면
원본 스냅샷의 비밀번호가 유지되는 사례가 보고되었다.
복원 시나리오에서는 적용 여부를 확인한다.

### deletion_protection

활성화한다. Terraform `destroy` 나 콘솔 삭제가 모두 차단된다.

2025년 8월 nx 공급망 공격에서 침해된 CI/CD 자격증명으로
프로덕션 RDS 가 삭제된 사례가 있었다.
이후 deletion protection 은 필수 baseline 컨트롤로 취급된다.

삭제하려면 먼저 이 값을 false 로 바꿔 apply 해야 한다.

### 최종 스냅샷

`skip_final_snapshot = false`, 식별자는 고정 문자열을 사용한다.

```hcl
final_snapshot_identifier = "${var.name_prefix}-rds-final"
```

`timestamp()` 를 넣으면 매 plan 마다 값이 달라져 불필요한 diff 가 생긴다.
같은 이름으로 두 번 삭제하면 충돌하나, 삭제 빈도가 낮아 그때 처리한다.

---

## 백업

| 항목 | 값 |
| --- | --- |
| 보존 기간 | 7일 |
| 백업 윈도우 | 19:00-20:00 UTC (KST 04:00-05:00) |
| 유지보수 윈도우 | sun:20:00-sun:21:00 UTC (KST 일 05:00-06:00) |
| `copy_tags_to_snapshot` | true |

### 윈도우 배치

**백업을 먼저, 유지보수를 그 뒤에 둔다.**
유지보수로 인한 변경 전에 항상 최신 백업이 확보된다.

시간대는 한국 사용자 기준 트래픽이 가장 낮은 새벽으로 잡았다.
유지보수는 일요일로 두어 문제 발생 시 대응 여유를 확보한다.

윈도우를 지정하지 않으면 AWS 가 임의로 정하며, 피크 시간대에 걸릴 수 있다.

### 비용

자동 백업은 **DB 크기만큼 무료**다.
20GB 인스턴스면 20GB 까지 스냅샷 저장에 비용이 없고 초과분만 과금된다.
7일 보존으로 초과할 가능성은 낮다.

### 복원

자동 백업은 일일 스냅샷과 트랜잭션 로그로 구성되어
**보존 기간 내 임의 시점 복원(PITR)** 이 가능하다.

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier logssey-prod-rds \
  --target-db-instance-identifier logssey-prod-rds-restored \
  --restore-time 2026-09-27T10:30:00Z
```

스키마 변경이나 마이그레이션 전에는 수동 스냅샷을 별도로 만든다.
수동 스냅샷은 삭제할 때까지 유지된다.

```bash
aws rds create-db-snapshot \
  --db-instance-identifier logssey-prod-rds \
  --db-snapshot-identifier logssey-prod-rds-before-migration-20260927
```

---

## 파라미터 그룹

커스텀 그룹을 생성한다. **기본 그룹(`default.postgres18`)은 수정할 수 없다.**

나중에 커스텀으로 교체하려면 인스턴스 수정과 재부팅이 필요하므로,
처음부터 커스텀 그룹을 붙여 이후 변경을 자유롭게 한다.

| 파라미터 | 값 | 유형 |
| --- | --- | --- |
| `rds.force_ssl` | 1 | static (재부팅 필요) |

**나머지는 기본값을 유지한다.**

로그 관련 파라미터는 백엔드의 쿼리 패턴이 확정된 뒤 조정한다.
기본값이 이미 보수적이라 CloudWatch 비용 문제도 없다.

| 파라미터 | 기본값 | 의미 |
| --- | --- | --- |
| `log_statement` | none | 쿼리 로깅 안 함 |
| `log_min_duration_statement` | -1 | 느린 쿼리 로깅 안 함 |

### 파라미터 유형

| 유형 | 적용 | 예시 |
| --- | --- | --- |
| dynamic | 즉시 | `log_statement`, `log_connections` |
| static | 재부팅 필요 | `rds.force_ssl`, `max_connections`, `shared_buffers` |

로그 관련은 대부분 dynamic 이라 나중에 무중단으로 조정할 수 있다.

---

## 모니터링 — 미적용

비용 관리를 위해 아래를 비활성화한다.

| 항목 | 비용 | 판단 |
| --- | --- | --- |
| Performance Insights | 7일 보존은 무료 | 현재 볼 사람이 없음. 필요 시 활성화 |
| Enhanced Monitoring | CloudWatch 커스텀 지표 과금 | 비활성 |
| CloudWatch 로그 export | 수집 GB 당 과금 | 비활성 |

db.t4g.small 은 Performance Insights 를 지원한다(확인됨).
성능 분석이 필요해지면 활성화한다. 재부팅 없이 변경 가능하다.

### 로그 export 를 끄는 것의 의미

로그는 인스턴스 디스크에 파일로 남으며 콘솔이나 CLI 로 조회할 수 있다.

```bash
aws rds describe-db-log-files --db-instance-identifier logssey-prod-rds
aws rds download-db-log-file-portion \
  --db-instance-identifier logssey-prod-rds --log-file-name <name>
```

**제약이 있다.**

| 항목 | 기본 로그 | CloudWatch export |
| --- | --- | --- |
| 보존 | 짧음. 자동 삭제 | 설정한 대로 |
| 검색 | 파일 단위 다운로드 | Logs Insights 쿼리 |
| 인스턴스 삭제 시 | 함께 사라짐 | 남음 |
| 알림 | 불가 | 메트릭 필터로 가능 |

**감사 로그가 필요해지면 활성화한다.**
"언제 누가 접속했는가" 를 사후에 확인하려면 CloudWatch 로 내보내야 한다.
보안 대시보드 프로젝트 특성상 후속 단계에서 다시 검토할 항목이다.

---

## 계정 구조

Terraform 은 **마스터 계정만** 생성한다.

| 계정 | 용도 | 생성 주체 |
| --- | --- | --- |
| logssey_admin | 스키마 변경, 계정 관리 | Terraform |
| 애플리케이션 계정 | 서비스 런타임 | 마이그레이션 도구 또는 초기화 SQL |

**마스터 계정을 애플리케이션이 직접 쓰지 않는다.**
애플리케이션 계정은 특정 DB 의 CRUD 권한만 갖도록 제한해,
유출되더라도 스키마 삭제 같은 피해를 막는다.

계정 분리는 DB 접속 후 SQL 로 수행하므로 Terraform 영역이 아니다.
백엔드 작업 시점에 정의한다.

마스터 사용자명은 기본값 `postgres` 를 피한다.
사용자명 자체가 보안 경계는 아니나, 스캐너가 먼저 시도하는 이름이다.

---

## 비용

| 항목 | 단가 | 월 (USD) |
| --- | --- | --- |
| db.t4g.small | 약 $0.041/hr | 약 30 |
| gp3 20GB | $0.131/GB | 약 2.6 |
| 자동 백업 7일 | DB 크기까지 무료 | 0 |
| Secrets Manager 1개 | $0.40/월 | 0.4 |
| **합계** | | **약 33** |

도쿄 리전 기준, 730시간 환산. 2026-09 시점 요금이다.

T4g 는 버스터블이므로 베이스라인을 초과해 지속 사용하면 추가 과금이 발생한다.
실제 청구액은 Cost Explorer 에서 확인한다.

---

## 확인

인스턴스 상태

```bash
aws rds describe-db-instances \
  --db-instance-identifier logssey-prod-rds \
  --region ap-northeast-1 \
  --query 'DBInstances[0].[DBInstanceStatus,Engine,EngineVersion,DBInstanceClass,MultiAZ,StorageEncrypted,PubliclyAccessible,DeletionProtection]' \
  --output table
```

엔드포인트

```bash
aws rds describe-db-instances \
  --db-instance-identifier logssey-prod-rds \
  --region ap-northeast-1 \
  --query 'DBInstances[0].Endpoint.[Address,Port]' \
  --output text
```

비밀번호 조회 — Secrets Manager

```bash
SECRET_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier logssey-prod-rds \
  --region ap-northeast-1 \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

aws secretsmanager get-secret-value \
  --secret-id $SECRET_ARN \
  --region ap-northeast-1 \
  --query 'SecretString' --output text
```

파라미터 확인

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name logssey-prod-pg18 \
  --region ap-northeast-1 \
  --query "Parameters[?ParameterName=='rds.force_ssl'].[ParameterName,ParameterValue,ApplyType]" \
  --output table
```

연결 테스트 — Worker Pod 에서

```bash
kubectl run pgtest --rm -it --image=postgres:18-alpine --restart=Never -- \
  psql "postgresql://logssey_admin:<password>@<endpoint>:5432/reused?sslmode=require" -c "SELECT version();"
```

SSL 강제가 동작하는지 확인하려면 `sslmode=disable` 로 시도해 거부되는지 본다.

---

## 확장 항목

| 항목 | 시점 |
| --- | --- |
| Multi-AZ | 실 트래픽 또는 가용성 요구 발생 시 |
| 인스턴스 클래스 상향 | 연결 수 또는 메모리 부족 시 |
| Performance Insights | 쿼리 성능 분석 필요 시 |
| CloudWatch 로그 export | 감사 로그 요구 발생 시 |
| 읽기 전용 복제본 | 조회 부하 분산 필요 시 |
| 비밀번호 자동 로테이션 | `aws_secretsmanager_secret_rotation` 으로 설정 |
| `sslmode=verify-full` | RDS CA 번들 배포 후 |
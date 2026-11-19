# IaC 보안 정책 (plan 전 검사)

PR 의 `.tf` 를 `terraform init`·`plan` 전에 Conftest 로 검사한다.
규칙 ID·강도·심각도는 [IaC 보안 규칙 명세](https://github.com/Logssey/security-solution-docs/blob/main/iac-security/02-functional-design/rule-spec.md) 와 같다.

| 파일 | 내용 |
| --- | --- |
| `gate.rego` | 규칙. `deny` = 차단, `warn` = 경고 |
| `gate_test.rego` | 단위 테스트. 위험 시나리오 S1~S4·S6 와 경계 사례 |
| `gate.sh` | plan 전 검사 전체 (관문 0·1·2·3·2b). CI 와 `make plan` 이 같이 쓴다 |
| `module-hashes.txt` | 원격 모듈 내용 해시 기준 (관문 2b) |
| `dashboard-run.sh` | `iac-report` 가 IaC 보안 대시보드에 올릴 실행 등록 본문 (테스트 `dashboard-run_test.sh`) |
| `path-report.sh` | 대시보드의 경로 분석 결과로 "경로 분석" 검사·코멘트 절 만들기 (테스트 `path-report_test.sh`) |

## 실행

Conftest 버전은 v0.71.1 로 고정한다.

```bash
# 단위 테스트
conftest verify --policy policy

# 실제 코드 검사 (.terraform 아래와 .tf 가 아닌 파일은 제외)
find terraform -name '*.tf' -not -path '*/.terraform/*' -print0 \
  | xargs -0 conftest test --parser hcl2 --policy policy
```

## gate (plan 전 검사)

`gate.sh` 는 AWS 자격 증명 없이 돌고, 차단이 하나라도 있으면 멈춘다. Terraform 은 1.16.5 로 고정한다.

| 관문 | 내용 | 결과 |
| --- | --- | --- |
| 0·1 | 워크플로·lock 파일 변경 / backend·cloud 블록 변경 | 경고 / 차단 |
| 2 | `.tf` 정적 검사, `.tf.json`·커밋된 `.terraform/` 거부 | 규칙대로 |
| 3 | `terraform init -backend=false -lockfile=readonly` | 실패 시 차단 |
| 2b | 내려받은 원격 모듈 재검사 + 내용 해시를 `module-hashes.txt` 와 비교 | 규칙대로 / 해시 다르면 차단 |

```bash
# 로컬 (관문 0·1 생략)
policy/gate.sh

# 변경 감지까지 (CI 와 같음)
GATE_BASE=origin/develop policy/gate.sh
```

- 관문 0·1 은 `GATE_BASE` 가 있을 때만 돈다.
- init 결과는 `.terraform` 이 아니라 `.terraform-gate` 에 둔다. backend 가 초기화된 `.terraform` 이 있으면 `-backend=false` 라도 자격 증명을 찾기 때문이다.
- 원격 모듈을 추가하거나 버전을 바꾸면 "기준 해시 없음" 경고와 함께 줄이 출력된다. 모듈 내용을 검토한 뒤 그 줄을 `module-hashes.txt` 에 붙인다.

## 로컬 plan (`make plan`)

레포 루트에서 실행한다. 필요 도구: make, docker, aws CLI, jq, git, curl, unzip.

```bash
make plan            # gate → plan (ENV=prod)
make gate            # gate 만, 자격 증명 없음
```

1. `make tools` 가 conftest·terraform 을 버전과 체크섬으로 고정해 `.tools/bin` 에 받는다.
2. `gate.sh` 가 돌고, 차단이면 자격 증명을 받기 전에 멈춘다.
3. 내 IAM 사용자로 plan-ro Role 을 assume 한다 (1시간, 세션 이름 = 사용자 이름).
4. 이미지 digest 로 고정한 Terraform 컨테이너에서 `plan -lock=false` 를 돈다.
    - 컨테이너에는 `terraform/` 만 읽기 전용으로 들어간다. 홈 디렉터리·`~/.aws`·장기 키는 들어가지 않는다.
    - gate 가 검사한 `.terraform-gate` 의 모듈·프로바이더를 그대로 쓴다.
    - 사람이 쓰는 `.terraform` 은 건드리지 않는다.

plan-ro Role 을 쓸 수 있는 사람은 `terraform/environments/prod/main.tf` 의 `iac_plan_local_users` 로 정한다.

## 대시보드 전송 (`iac-report`)

`iac-report` 는 PR 검사·코멘트를 등록한 뒤, 같은 결과와 민감값을 지운 plan 을 IaC 보안 대시보드에 올린다.
대시보드가 경로 분석과 State 점검을 하고 IaC 탭에 PR 판정을 보여 준다.

- 인증: GitHub Actions OIDC 토큰(aud `logssey-iac`). 대시보드는 sub 가 `repo:Logssey/infrastructure:environment:iac-app` 인 토큰만 받는다. `iac-app` 은 main 만 쓰는 environment 라 PR 코드는 이 토큰을 받을 수 없다
- 설정: 레포 변수 `IAC_DASHBOARD_URL` (예: `https://logssey.re-used.store`). 없으면 대시보드 전송 단계를 건너뛴다
- 실패해도 PR 검사·코멘트는 그대로 남고 경고만 남긴다 (대시보드 장애가 PR 을 막지 않게)
- 통과·차단 기준은 `report.sh` 와 같다. 검사 코드(.github/, policy/)를 바꾼 PR 은 차단으로 올린다
- 분석이 끝나기를 최대 5분 기다려 검사 "경로 분석"을 등록하고 요약 코멘트에 경로 분석 절을 붙인다
  - 1등급 새 경로(차단) → 실패, 경고 → 중립, 좋아짐·변화 없음 → 성공. plan 전 검사에서 막혀 분석 안 함 → 실패
  - 대시보드에 닿지 못함·plan 없음·대기 시간 초과 → 중립
  - 아직 필수 검사가 아니다. 끝에서 끝 검증 뒤에 필수로 지정한다

## main 매일 점검 (`iac-drift`)

매일 02:30 KST(와 수동 실행)에 main 코드로 `gate.sh` 와 `terraform plan`(refresh 포함)을 돌려 결과를 대시보드에 올린다 (trigger PUSH).
대시보드는 main 기준 plan 전 검사 위반과, plan 의 `resource_drift` 로 분류한 드리프트를 보여 준다.

- environment `iac-drift`: main 만 쓰고 비밀값이 없다. 이 sub 로 plan-ro Role 을 받고(신뢰 정책), 대시보드에는 main 점검만 등록할 수 있다
- 레포 변수: `IAC_PLAN_ROLE_ARN`, `IAC_PLAN_OWNER`(iac-gate 와 같음), `IAC_DASHBOARD_URL`
- gate 차단·plan 실패도 대시보드에 남긴 뒤 워크플로를 실패로 표시한다

## 규칙을 바꿀 때

- PR 로만 바꾼다. 이 폴더는 CODEOWNERS 로 security-team 리뷰 대상이다.
- `policy/`·`.github/` 를 바꾼 PR 은 "plan 전 검사" 가 `gate.check_code_changed` 로 차단된다. PR 이 바꾼 검사 코드로 만든 결과라 믿지 않기 때문이다. 보안 리뷰 후 ruleset 우회 권한이 있는 관리자가 병합한다.
- 바꾼 규칙에는 차단·통과 테스트를 함께 추가한다.
- 실제 코드 검사에서 FAIL·WARN 이 없어야 한다 (오탐 0).

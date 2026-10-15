# IaC 보안 정책 (② plan 전 검사)

PR 의 `.tf` 를 `terraform init`·`plan` 전에 Conftest 로 검사한다.
규칙 ID·강도·심각도는 [IaC 보안 규칙 명세](https://github.com/Logssey/security-solution-docs/blob/main/iac-security/02-functional-design/rule-spec.md) 와 같다.

| 파일 | 내용 |
| --- | --- |
| `gate.rego` | 규칙. `deny` = 차단, `warn` = 경고 |
| `gate_test.rego` | 단위 테스트. 위험 시나리오 S1~S4·S6 와 경계 사례 |
| `gate.sh` | plan 전 검사 전체 (관문 0·1·2·3·2b). CI 와 `make plan` 이 같이 쓴다 |
| `module-hashes.txt` | 원격 모듈 내용 해시 기준 (관문 2b) |

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
| 2b | 내려받은 원격 모듈 재검사 + 내용 해시를 `module-hashes.txt` 와 비교 | 규칙대로 / 경고 |

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

## 규칙을 바꿀 때

- PR 로만 바꾼다. 이 폴더는 CODEOWNERS 로 security-team 리뷰 대상이다.
- 바꾼 규칙에는 차단·통과 테스트를 함께 추가한다.
- 실제 코드 검사에서 FAIL·WARN 이 없어야 한다 (오탐 0).

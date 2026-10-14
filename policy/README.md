# IaC 보안 정책 (② plan 전 검사)

PR 의 `.tf` 를 `terraform init`·`plan` 전에 Conftest 로 검사한다.
규칙 ID·강도·심각도는 [IaC 보안 규칙 명세](https://github.com/Logssey/security-solution-docs/blob/main/iac-security/02-functional-design/rule-spec.md) 와 같다.

| 파일 | 내용 |
| --- | --- |
| `gate.rego` | 규칙. `deny` = 차단, `warn` = 경고 |
| `gate_test.rego` | 단위 테스트. 위험 시나리오 S1~S4·S6 와 경계 사례 |

## 실행

Conftest 버전은 v0.71.1 로 고정한다.

```bash
# 단위 테스트
conftest verify --policy policy

# 실제 코드 검사 (.terraform 아래와 .tf 가 아닌 파일은 제외)
find terraform -name '*.tf' -not -path '*/.terraform/*' -print0 \
  | xargs -0 conftest test --parser hcl2 --policy policy
```

## 규칙을 바꿀 때

- PR 로만 바꾼다. 이 폴더는 CODEOWNERS 로 security-team 리뷰 대상이다.
- 바꾼 규칙에는 차단·통과 테스트를 함께 추가한다.
- 실제 코드 검사에서 FAIL·WARN 이 없어야 한다 (오탐 0).

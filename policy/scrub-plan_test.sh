#!/usr/bin/env bash
# ─────────────────────────────────────────────
# scrub-plan.sh 테스트
#
# 실제 Terraform 이 만든 plan JSON(testdata/scrub-plan/plan.json)으로
#   1. 민감값(FIXTURE-SECRET-*)이 하나도 남지 않는지
#   2. 키 구조가 그대로인지
#   3. 바뀐 값이 모두 "(sensitive)" 인지 (민감하지 않은 값은 그대로)
# 를 확인한다.
# ─────────────────────────────────────────────

set -euo pipefail

cd "$(dirname "$0")"
in=testdata/scrub-plan/plan.json
out=$(mktemp)
trap 'rm -f "$out"' EXIT

./scrub-plan.sh "$in" >"$out"

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "PASS - $1"; else echo "FAIL - $1 (기대 $3, 실제 $2)"; fail=1; fi
}

check "원본에 민감값이 있음" "$(grep -c FIXTURE-SECRET "$in" | tr -d '\n')" 32
check "민감값 0" "$(grep -c FIXTURE-SECRET "$out" || true)" 0
check "키 구조 유지" "$(jq -c '[paths] | sort' "$out" | sha256sum)" "$(jq -c '[paths] | sort' "$in" | sha256sum)"

scalars='paths(scalars) as $p | [$p, getpath($p)] | tojson'
changed=$(diff <(jq -r "$scalars" "$in") <(jq -r "$scalars" "$out") | grep '^>' || true)
check "바뀐 값은 모두 (sensitive)" "$(grep -vc '"(sensitive)"\]$' <<<"$changed" || true)" 0

check "민감하지 않은 값 유지" \
  "$(jq -c '[(.resource_changes[] | select(.address == "terraform_data.partial") | .change.after.input.username),
             .variables.region.value, .output_changes.plain_out.after]' "$out")" \
  '["app","ap-northeast-1","ap-northeast-1"]'

exit $fail

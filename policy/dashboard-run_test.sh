#!/usr/bin/env bash
# ─────────────────────────────────────────────
# dashboard-run.sh 테스트
#
# result.json 모양별로 대시보드 실행 등록 본문이
#   1. 통과·차단 상태를 report.sh 와 같은 기준으로 정하는지
#   2. 규칙 ID 가 있는 발견 건만, 길이를 잘라 보내는지
#   3. 검사 코드를 바꾼 PR 은 차단으로 보내는지
#   4. main 매일 점검(pr 없음)은 PUSH 로 보내는지
#   5. PR 제목을 256자까지 보내고, 없거나 main 점검이면 보내지 않는지
# 를 확인한다.
# ─────────────────────────────────────────────

set -euo pipefail

cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sha=$(printf 'a%.0s' {1..40})

result() { # gate plan findings(JSON 배열)
  jq -n --arg sha "$sha" --arg gate "$1" --arg plan "$2" --argjson findings "$3" \
    '{version: 1, pr: 58, head_sha: $sha, gate: $gate, plan: $plan, plan_counts: null, findings: $findings}' >"$tmp/result.json"
}

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "PASS - $1"; else echo "FAIL - $1 (기대 $3, 실제 $2)"; fail=1; fi
}

result success success '[{"level":"warn","msg":"[gate.lock_changed] lock 파일 변경: .terraform.lock.hcl"}]'
body=$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure)
check "경고만 있으면 통과" "$(jq -r .gate.status <<<"$body")" PASSED
check "레포·PR·SHA·트리거" "$(jq -c '[.repo, .prNumber, .headSha == "'"$sha"'", .trigger]' <<<"$body")" '["Logssey/infrastructure",58,true,"PR"]'
check "발견 건 그대로" "$(jq -c .gate.findings <<<"$body")" '[{"level":"warn","msg":"[gate.lock_changed] lock 파일 변경: .terraform.lock.hcl"}]'

result failure skipped '[{"level":"block","msg":"[gate.provisioner] local-exec: aws_instance.a"},{"level":"warn","msg":"규칙 ID 없는 줄"}]'
body=$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure)
check "차단 발견 건이면 차단" "$(jq -r .gate.status <<<"$body")" BLOCKED
check "규칙 ID 없는 줄은 빼고 보냄" "$(jq -r '.gate.findings | map(.msg[0:16]) | join(",")' <<<"$body")" "[gate.provisione"

result success failure '[{"level":"block","msg":"[gate.plan_failed] terraform plan 실패"}]'
check "plan 실패면 차단" "$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure | jq -r .gate.status)" BLOCKED

result cancelled skipped '[]'
check "gate 가 끝나지 않았으면 차단 (fail-closed)" "$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure | jq -r .gate.status)" BLOCKED

result success success '[]'
printf 'terraform/main.tf\npolicy/gate.rego\n' >"$tmp/changed.txt"
body=$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure "$tmp/changed.txt")
check "검사 코드를 바꾼 PR 은 차단" "$(jq -r .gate.status <<<"$body")" BLOCKED
check "검사 코드 변경 표시는 보내지 않음" "$(jq '.gate.findings | length' <<<"$body")" 0
printf 'terraform/main.tf\n' >"$tmp/changed.txt"
check "Terraform 만 바꾼 PR 은 통과" "$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure "$tmp/changed.txt" | jq -r .gate.status)" PASSED

result success success '[]'
printf 'Grafana 내 IP 로만 열기\n' >"$tmp/title.txt"
body=$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure /dev/null "$tmp/title.txt")
check "PR 제목을 보냄 (끝 줄바꿈 없이)" "$(jq -r .prTitle <<<"$body")" "Grafana 내 IP 로만 열기"
check "제목이 없으면 보내지 않음" "$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure | jq 'has("prTitle")')" false
head -c 400 /dev/zero | tr '\0' 'x' >"$tmp/title.txt"
check "제목은 256자까지" "$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure /dev/null "$tmp/title.txt" | jq '.prTitle | length')" 256

jq -n --arg sha "$sha" '{version: 1, pr: null, head_sha: $sha, gate: "success", plan: "success", plan_counts: null,
  findings: [{level: "warn", msg: "[gate.provider_unpinned] 버전 없음: terraform/x"}]}' >"$tmp/result.json"
body=$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure)
check "main 매일 점검(pr 없음)은 PUSH, PR 번호 없음" "$(jq -c '[.trigger, has("prNumber"), .gate.status]' <<<"$body")" '["PUSH",false,"PASSED"]'
check "main 점검도 발견 건을 보냄" "$(jq '.gate.findings | length' <<<"$body")" 1
check "main 점검에는 제목을 보내지 않음" "$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure /dev/null "$tmp/title.txt" | jq 'has("prTitle")')" false

jq -n --arg sha "$sha" '{version: 1, pr: 58, head_sha: $sha, gate: "success", plan: "success", plan_counts: null,
  findings: [range(0; 250) | {level: "warn", msg: ("[gate.lock_changed] " + ("x" * 600))}]}' >"$tmp/result.json"
body=$(./dashboard-run.sh "$tmp/result.json" Logssey/infrastructure)
check "발견 건 200건까지" "$(jq '.gate.findings | length' <<<"$body")" 200
check "문구 500자까지" "$(jq '[.gate.findings[].msg | length] | max' <<<"$body")" 500

exit $fail

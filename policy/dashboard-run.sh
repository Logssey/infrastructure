#!/usr/bin/env bash
# ─────────────────────────────────────────────
# IaC 보안 대시보드에 올릴 PR 실행 등록 본문 만들기 (POST /api/v1/iac/runs)
#
# iac-report 워크플로(기본 브랜치 코드)가 report.sh 로 형식을 검사한 result.json 으로 부른다.
# iac-drift 워크플로(main 매일 점검)는 pr 이 null 인 result.json 으로 부른다 → trigger PUSH, PR 번호 없음.
# 여기서는 API 를 부르지 않는다.
#
#   - gate 가 성공하지 않았거나, 차단 발견 건이 있거나, plan 이 실패했거나,
#     PR 이 검사 코드(.github/, policy/)를 바꿨으면 BLOCKED (report.sh 와 같은 기준, fail-closed)
#   - 발견 건은 "[gate.규칙] 문구" 모양만 보낸다. 문구는 500자, 건수는 200건까지 (API 계약)
#   - gate.check_code_changed 는 PR 코멘트 전용이라 보내지 않는다 (상태가 BLOCKED 로 대신한다)
#
# 사용법: policy/dashboard-run.sh result.json 레포(owner/name) [변경파일목록]
# ─────────────────────────────────────────────

set -euo pipefail

result=$1
repo=$2
changed=${3:-/dev/null}

jq -c --arg repo "$repo" --rawfile changed "$changed" '
  ([$changed | split("\n")[] | select(test("^(\\.github|policy)/"))] | length > 0) as $check_code_changed
  | [.findings[] | select(.msg | test("^\\[gate\\.[a-z_]+\\] "))
                 | select(.msg | startswith("[gate.check_code_changed]") | not)
                 | {level, msg: .msg[0:500]}][0:200] as $findings
  | (.gate != "success" or .plan == "failure" or $check_code_changed
     or any(.findings[]; .level == "block")) as $blocked
  | {repo: $repo, headSha: .head_sha,
     gate: {status: (if $blocked then "BLOCKED" else "PASSED" end), findings: $findings}}
  + (if .pr == null then {trigger: "PUSH"} else {prNumber: .pr, trigger: "PR"} end)
' "$result"

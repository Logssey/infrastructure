#!/usr/bin/env bash
# ─────────────────────────────────────────────
# IaC 보안 PR 검사 결과·코멘트 만들기
#
# iac-gate 가 남긴 result.json(PR 코드로 만든 데이터)을 검사해 PR 에 올릴 내용을 만든다.
# iac-report 워크플로(기본 브랜치 코드)가 쓴다. 여기서는 GitHub API 를 부르지 않는다.
#
#   - 형식이 틀린 결과는 받지 않는다 (종료 코드 1)
#   - rules.json 에 없는 규칙 ID 는 차단으로 본다 (fail-closed)
#   - 발견 건 문구는 허용 문자·길이 안일 때만 그대로 쓰고, 아니면 표시하지 않는다
#
# 사용법: policy/report.sh result.json 출력디렉터리
#   출력: conclusion (success|neutral|failure), title, body.md (코멘트 본문, 숨은 표식 포함)
# ─────────────────────────────────────────────

set -euo pipefail

result=$1
out=$2
rules="$(dirname "$0")/rules.json"

jq -e '
  .version == 1
  and (.pr | type == "number" and . > 0 and . == floor)
  and (.head_sha | type == "string" and test("^[0-9a-f]{40}$"))
  and (.gate | IN("success", "failure", "cancelled", "skipped"))
  and (.plan | IN("success", "failure", "cancelled", "skipped", "fork"))
  and (.plan_counts == null or (.plan_counts | to_entries | length == 4 and all(.value | type == "number" and . >= 0)))
  and (.findings | type == "array" and length <= 200
       and all(type == "object" and (.level | IN("block", "warn")) and (.msg | type == "string")))
' "$result" >/dev/null || { echo "result.json 형식이 맞지 않음" >&2; exit 1; }

mkdir -p "$out"

jq -r --slurpfile rules "$rules" '
  . as $res
  | $rules[0] as $r
  | ["CRITICAL", "HIGH", "MEDIUM", "LOW", "없음"] as $sev

  # 발견 건 → {id, enforcement, severity, title, detail}
  | [$res.findings[] | .msg as $m
     | ($m | capture("^\\[(?<id>gate\\.[a-z_]+)\\] (?<text>.*)$") // {id: null, text: $m}) as $c
     | ($r[$c.id // ""] // null) as $rule
     | ($c.text | if test(": ") then sub("^[^:]*: "; "") else . end) as $d
     | {
         id: ($c.id // "알 수 없음"),
         enforcement: ($rule.enforcement // "차단"),
         severity: ($rule.severity // "HIGH"),
         title: ($rule.title // "알 수 없는 규칙 (차단으로 처리)"),
         detail: (if $d | test("^[\\p{Hangul}A-Za-z0-9 ._:/()\\[\\]\"@,=*+#~-]{1,200}$") then $d else "(표시 안 함: 허용 밖 문자 또는 길이)" end)
       }]
  | sort_by((if .enforcement == "차단" then 0 else 1 end), (.severity as $s | $sev | index($s) // 9)) as $f

  | (if ($f | any(.enforcement == "차단")) or $res.gate != "success" or ($res.plan | IN("failure", "cancelled")) then "failure"
     elif ($f | length) > 0 then "neutral"
     else "success" end) as $conclusion

  | {success: "통과", neutral: "확인 필요", failure: "차단"}[$conclusion] as $word

  | $res.plan_counts as $n
  | (if $res.plan == "success" and $n then
       "추가 \($n.add) · 변경 \($n.change) · 삭제 \($n.destroy) · 출력 변경 \($n.outputs)"
     elif $res.plan == "fork" then "plan 안 함: 포크 PR 은 OIDC 토큰을 받지 못함. gate 결과만 유효"
     elif $res.plan == "failure" then "plan 실패 (`gate.plan_failed`)"
     elif $res.gate != "success" then "plan 안 함: gate 에서 멈춤"
     else "plan 결과 없음 (\($res.plan))" end) as $plan

  | ([
      "<!-- logssey-iac -->",
      "### IaC 검사: \($word)",
      "",
      "대상 커밋 `\($res.head_sha[0:7])`",
      "",
      "**② plan 전 검사**",
      "",
      (if ($f | length) == 0 then
         (if $res.gate == "success" then "발견 없음" else "gate 실행 실패 (규칙 발견 없이 멈춤). Actions 로그 확인 필요" end)
       else
         "| 강도 | 심각도 | 규칙 | 대상 |",
         "| --- | --- | --- | --- |",
         ($f[] | "| \(.enforcement) | \(.severity) | `\(.id)` \(.title) | \(.detail) |")
       end),
      "",
      "**plan (prod)**",
      "",
      $plan
    ] | join("\n")) as $body

  | ($conclusion, "IaC 검사: \($word)", $body)
' "$result" | {
  IFS= read -r conclusion
  IFS= read -r title
  cat >"$out/body.md"
  printf '%s\n' "$conclusion" >"$out/conclusion"
  printf '%s\n' "$title" >"$out/title"
}

#!/usr/bin/env bash
# ─────────────────────────────────────────────
# IaC 보안 "경로 분석" 검사 결과·코멘트 절 만들기 (경로 분석, State)
#
# iac-report 워크플로(기본 브랜치 코드)가 대시보드 API 의 run 결과(GET /api/v1/iac/runs/{id}/result)로 부른다.
# 여기서는 API 를 부르지 않는다.
#
#   - 판정: BLOCK → 실패, WARN → 중립, INFO·PASS → 성공
#   - plan 전 검사에서 막혀 분석하지 못했으면 실패 ("건너뜀"으로 두면 필수 검사가 비어 병합될 수 있어서)
#   - 분석이 끝나지 않았거나(대기 시간 초과) 오류면 중립
#   - 그래프에서 온 이름·주소는 허용 문자·길이 안일 때만 그대로 쓰고, 아니면 표시하지 않는다
#
# 사용법: policy/path-report.sh run-result.json 출력디렉터리 대시보드주소
#   출력: conclusion (success|neutral|failure), title, section.md (요약 코멘트에 붙일 경로 분석 절)
# ─────────────────────────────────────────────

set -euo pipefail

result=$1
out=$2
dashboard=${3%/}

jq -e '
  (.runId | type == "number")
  and (.status | IN("QUEUED", "GATE_FAILED", "PLANNING", "ANALYZING", "DONE", "ERROR", "SUPERSEDED"))
  and (.verdict == null or (.verdict | IN("BLOCK", "WARN", "INFO", "PASS")))
  and ((.paths // []) | type == "array")
  and ((.resourceFindings // []) | type == "array")
' "$result" >/dev/null || { echo "run 결과 형식이 맞지 않음" >&2; exit 1; }

mkdir -p "$out"

jq -r --arg dashboard "$dashboard" '
  def safe: if type == "string" and test("^[\\p{Hangul}A-Za-z0-9 ._:/()\\[\\]\"@,=*+#~-]{1,200}$") then . else "(표시 안 함)" end;
  def title: {
      "path.tier1.added": "1등급 데이터까지 새 경로", "path.tier2.added": "2등급 데이터까지 새 경로",
      "path.shortened": "기존 경로가 짧아짐", "path.imds_v1_added": "IMDSv1 인스턴스 추가",
      "path.removed": "경로가 사라짐", "state.reader_increase": "State 읽기 주체 증가"
    }[.] // "알 수 없는 규칙";
  def enforcement: {"path.tier1.added": "차단", "path.removed": "정보"}[.] // "경고";
  def hop: if .kind == "Internet" then "인터넷"
           elif .kind == "AWSCloudFrontDistribution" then "CloudFront \(.name | tostring | split("/") | last | safe)"
           else (.name | safe) end;
  def cause: if .cause.address then "`\(.cause.address | safe)` (\({CREATE: "추가", UPDATE: "변경", DELETE: "삭제", REPLACE: "교체"}[.cause.action] // "변경"))" else "-" end;

  . as $r
  | [($r.paths // [])[] | select(.change != "REMOVED")] as $risky
  | [($r.paths // [])[] | select(.change == "REMOVED")] as $removed
  | ($r.resourceFindings // []) as $resources
  | ($r.state // {}) as $state

  | (if $r.status == "GATE_FAILED" then ["failure", "차단 (plan 전 검사에서 멈춰 분석 안 함)"]
     elif $r.status == "DONE" then
       {BLOCK: ["failure", "차단"], WARN: ["neutral", "확인 필요"], INFO: ["success", "좋아짐"], PASS: ["success", "새 경로 없음"]}[$r.verdict]
       // ["neutral", "판정 없음"]
     elif $r.status == "ERROR" then ["neutral", "분석 실패 (대시보드 확인 필요)"]
     elif $r.status == "SUPERSEDED" then ["neutral", "새 커밋으로 대체됨"]
     else ["neutral", "분석 대기 시간 초과 (대시보드에서 결과 확인)"] end) as [$conclusion, $word]

  | ([
      "",
      "**경로 분석: \($word)**",
      "",
      (if $r.status != "DONE" then
         (if $r.status == "GATE_FAILED" then "plan 전 검사에서 막혀 plan·경로 분석을 하지 않았어요." else "결과가 아직 없어요." end)
       else
         "새 경로 \($risky | map(select(.change == "ADDED")) | length) · 짧아짐 \($risky | map(select(.change == "SHORTENED")) | length) · 사라짐 \($removed | length)",
         (if ($risky | length) > 0 then
            "",
            "| 강도 | 심각도 | 규칙 | 경로 | 원인 |",
            "| --- | --- | --- | --- | --- |",
            ($risky | sort_by(.tier, (.ruleId | enforcement != "차단"))[0:10][]
              | "| \(.ruleId | enforcement) | \(.severity // "-") | `\(.ruleId | safe)` \(.ruleId | title) | \([.hops[]? | hop] | join(" → ")) | \(cause) |"),
            (if ($risky | length) > 10 then "", "외 \(($risky | length) - 10)개는 대시보드에서 확인" else empty end)
          else empty end),
         (if ($resources | length) > 0 then
            "",
            ($resources[0:10][] | "- \(.enforcement // "WARN" | {BLOCK: "차단", WARN: "경고", INFO: "정보"}[.] // "경고") · `\(.ruleId | safe)` \(.ruleId | title): `\(.address | safe)`")
          else empty end),
         "",
         (if $state.ruleId == "state.reader_increase" then
            "**State**: 경고 · `state.reader_increase` tfstate 를 읽을 수 있는 주체 \($state.readersBefore // "?") → \($state.readersAfter // "?")"
          elif $state.readersAfter != null then
            "**State**: 읽기 주체 변화 없음 (\($state.readersAfter))"
          else empty end)
       end),
      "",
      "[IaC 보안 대시보드에서 보기](\($dashboard)/iac)"
    ] | join("\n")) as $section

  | ($conclusion, "경로 분석: \($word)", $section)
' "$result" | {
  IFS= read -r conclusion
  IFS= read -r title
  cat >"$out/section.md"
  printf '%s\n' "$conclusion" >"$out/conclusion"
  printf '%s\n' "$title" >"$out/title"
}

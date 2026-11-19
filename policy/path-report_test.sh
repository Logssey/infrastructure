#!/usr/bin/env bash
# ─────────────────────────────────────────────
# path-report.sh 테스트
#
# 대시보드 run 결과 모양별로 "경로 분석" 검사가
#   1. 판정(차단·경고·좋아짐·변화 없음)을 검사 결론으로 맞게 바꾸는지
#   2. plan 전 검사에서 막힌 PR 은 "건너뜀"이 아니라 실패인지, 대기 시간 초과·오류는 중립인지
#   3. 새 경로·원인·State 를 코멘트 절에 보여 주고, 허용 밖 문자는 표시하지 않는지 (CloudFront 는 ID 만)
#   4. 요약 코멘트를 합칠 때 맨 위 제목이 두 결과 중 더 나쁜 쪽인지 (merge-comment.sh)
# 를 확인한다. 경로는 로컬 데모(#58 시나리오)의 실제 결과 모양이다.
# ─────────────────────────────────────────────

set -euo pipefail

cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "PASS - $1"; else echo "FAIL - $1 (기대 $3, 실제 $2)"; fail=1; fi
}
has() { # 이름 파일 문자열
  if grep -qF -- "$3" "$2"; then echo "PASS - $1"; else echo "FAIL - $1 ($3 없음)"; fail=1; fi
}
report() { # status verdict paths resourceFindings state
  jq -n --arg status "$1" --argjson verdict "$2" --argjson paths "$3" --argjson resources "$4" --argjson state "$5" \
    '{number: 58, runId: 7, status: $status, verdict: $verdict, paths: $paths, resourceFindings: $resources,
      state: $state, gate: {status: "PASS", findings: []}}' >"$tmp/result.json"
  rm -rf "$tmp/out"
  ./path-report.sh "$tmp/result.json" "$tmp/out" https://dashboard.example/
}

tier1='{"change":"ADDED","tier":1,"ruleId":"path.tier1.added","severity":"CRITICAL",
  "hops":[{"kind":"Internet","name":"internet"},
          {"kind":"AWSCloudFrontDistribution","name":"arn:aws:cloudfront::794386801311:distribution/E3NA9R8NTNSVRH"},
          {"kind":"AWSLoadBalancerV2","name":"logssey-prod-nlb-public"},
          {"kind":"AWSEC2Instance","name":"i-0c18628fa30035aa9"},{"kind":"AWSRole","name":"logssey-prod-role-node"},
          {"kind":"AWSS3Bucket","name":"logssey-prod-s3-tfstate"}],
  "cause":{"address":"module.iam.aws_iam_role_policy.deny_tfstate","action":"DELETE"}}'
removed='{"change":"REMOVED","tier":2,"ruleId":"path.removed","severity":null,"hops":[],"cause":null}'
reader='{"ruleId":"state.reader_increase","severity":"HIGH","readersBefore":5,"readersAfter":6}'
same='{"ruleId":null,"readersBefore":5,"readersAfter":5}'

report DONE '"BLOCK"' "[$tier1]" '[]' "$reader"
check "1등급 새 경로면 실패" "$(cat "$tmp/out/conclusion")" failure
check "제목" "$(cat "$tmp/out/title")" "경로 분석: 차단"
has "경로를 홉 순서로, CloudFront 는 ID 만" "$tmp/out/section.md" "인터넷 → CloudFront E3NA9R8NTNSVRH → logssey-prod-nlb-public → i-0c18628fa30035aa9 → logssey-prod-role-node → logssey-prod-s3-tfstate"
has "원인 리소스와 변경 종류" "$tmp/out/section.md" '`module.iam.aws_iam_role_policy.deny_tfstate` (삭제)'
has "강도·심각도·규칙" "$tmp/out/section.md" '| 차단 | CRITICAL | `path.tier1.added` 1등급 데이터까지 새 경로 |'
has "State 읽기 주체 증가" "$tmp/out/section.md" "주체 5 → 6"
has "대시보드 링크 (끝 / 없이)" "$tmp/out/section.md" "(https://dashboard.example/iac)"

report DONE '"WARN"' '[]' '[{"ruleId":"path.imds_v1_added","enforcement":"WARN","severity":"MEDIUM","address":"aws_instance.b","action":"CREATE"}]' "$same"
check "경고만 있으면 중립" "$(cat "$tmp/out/conclusion")" neutral
has "리소스 발견 건" "$tmp/out/section.md" '경고 · `path.imds_v1_added` IMDSv1 인스턴스 추가: `aws_instance.b`'
has "State 변화 없음" "$tmp/out/section.md" "읽기 주체 변화 없음 (5)"

report DONE '"INFO"' "[$removed,$removed]" '[]' "$same"
check "경로가 사라지기만 하면 성공" "$(cat "$tmp/out/conclusion")" success
has "사라진 경로 수" "$tmp/out/section.md" "새 경로 0 · 짧아짐 0 · 사라짐 2"

report DONE '"PASS"' '[]' '[]' "$same"
check "변화 없으면 성공" "$(cat "$tmp/out/title")" "경로 분석: 새 경로 없음"

report GATE_FAILED '"BLOCK"' '[]' '[]' 'null'
check "plan 전 검사에서 막히면 건너뜀이 아니라 실패" "$(cat "$tmp/out/conclusion")" failure

report ANALYZING 'null' '[]' '[]' 'null'
check "분석이 안 끝났으면 중립" "$(cat "$tmp/out/conclusion")" neutral
has "대기 시간 초과 문구" "$tmp/out/title" "대기 시간 초과"

report ERROR 'null' '[]' '[]' 'null'
check "분석 오류는 중립" "$(cat "$tmp/out/conclusion")" neutral

bad=$(jq -c '.hops[2].name = "<img src=x onerror=alert(1)>"' <<<"$tier1")
report DONE '"BLOCK"' "[$bad]" '[]' "$same"
has "허용 밖 이름은 표시 안 함" "$tmp/out/section.md" "→ (표시 안 함) →"
check "태그가 남지 않음" "$(grep -c '<img' "$tmp/out/section.md" || true)" 0

many=$(jq -nc --argjson p "$tier1" '[range(0; 12) | $p]')
report DONE '"BLOCK"' "$many" '[]' "$same"
check "경로 표는 10개까지" "$(grep -c '^| 차단 |' "$tmp/out/section.md")" 10
has "나머지는 대시보드로" "$tmp/out/section.md" "외 2개는 대시보드에서 확인"

# 요약 코멘트 합치기 (merge-comment.sh): 맨 위 제목은 두 결과 중 더 나쁜 쪽
printf '<!-- logssey-iac -->\n### IaC 검사: 통과\n\n**plan 전 검사**\n\n발견 없음\n' >"$tmp/body.md"
printf '\n**경로 분석: 차단**\n' >"$tmp/section.md"
merged=$(./merge-comment.sh "$tmp/body.md" success "$tmp/section.md" failure)
check "경로 분석이 차단이면 제목도 차단" "$(sed -n 2p <<<"$merged")" "### IaC 검사: 차단"
check "숨은 표식 유지" "$(head -1 <<<"$merged")" "<!-- logssey-iac -->"
check "두 절이 모두 들어감" "$(grep -c '^\*\*' <<<"$merged")" 2
check "경고면 확인 필요" "$(./merge-comment.sh "$tmp/body.md" success "$tmp/section.md" neutral | sed -n 2p)" "### IaC 검사: 확인 필요"
check "plan 전 검사 차단은 경로가 성공이어도 차단" "$(./merge-comment.sh "$tmp/body.md" failure "$tmp/section.md" success | sed -n 2p)" "### IaC 검사: 차단"
check "둘 다 성공이면 통과" "$(./merge-comment.sh "$tmp/body.md" success "$tmp/section.md" success | sed -n 2p)" "### IaC 검사: 통과"

echo '{"status":"DONE"}' >"$tmp/result.json"
if ./path-report.sh "$tmp/result.json" "$tmp/out" https://dashboard.example 2>/dev/null; then
  echo "FAIL - 형식이 틀린 결과를 받음"; fail=1
else
  echo "PASS - 형식이 틀린 결과는 거부"
fi

exit $fail

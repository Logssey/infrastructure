#!/usr/bin/env bash
# ─────────────────────────────────────────────
# IaC 보안 요약 코멘트 합치기: plan 전 검사 절(report.sh 의 body.md) + 경로 분석 절(path-report.sh 의 section.md)
#
# 맨 위 제목("### IaC 검사: …")은 report.sh 가 plan 전 검사만 보고 단다. 경로 분석이 끝나면 두 결과 중
# 더 나쁜 쪽(차단 > 확인 필요 > 통과)으로 고친다. 그래야 경로가 차단인데 제목이 "통과"로 남지 않는다.
#
# 사용법: policy/merge-comment.sh body.md 게이트결론 section.md 경로결론   (결론: success|neutral|failure)
#   출력: 합친 코멘트 본문 (표준 출력)
# ─────────────────────────────────────────────

set -euo pipefail

body=$1
gate=$2
section=$3
path=$4

rank() { case "$1" in failure) echo 2 ;; neutral) echo 1 ;; *) echo 0 ;; esac; }
worst=$gate
[ "$(rank "$path")" -le "$(rank "$gate")" ] || worst=$path
case "$worst" in
  failure) word="차단" ;;
  neutral) word="확인 필요" ;;
  *) word="통과" ;;
esac

# 제목 줄 한 개만 바꾼다 (나머지 본문은 그대로)
sed "0,/^### IaC 검사: .*/s//### IaC 검사: $word/" "$body"
cat "$section"

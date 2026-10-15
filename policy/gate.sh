#!/usr/bin/env bash
# ─────────────────────────────────────────────
# IaC 보안 ② plan 전 검사 (gate)
#
# CI(iac-gate 워크플로)와 로컬 래퍼(make plan)가 같이 쓴다.
# AWS 자격 증명 없이 돌고, 하나라도 차단이면 plan 전에 멈춘다.
#
#   관문 0·1  변경 감지 (GATE_BASE 가 있을 때만. 로컬은 생략)
#   관문 2    .tf 정적 검사 (policy/gate.rego)
#   관문 3    terraform init -backend=false -lockfile=readonly
#   관문 2b   내려받은 원격 모듈 재검사 + 내용 해시 비교
#
# 규칙 ID 는 security-solution-docs/iac-security/02-functional-design/rule-spec.md 와 같다.
#
# 필요 도구: git, jq, conftest v0.71.1, terraform 1.16.5
# 환경 변수:
#   GATE_BASE    비교 기준 커밋 (PR 의 base SHA)
#   GATE_OUTPUT  github 이면 GitHub 주석 형식으로 출력
# ─────────────────────────────────────────────

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# init 결과를 .terraform 이 아닌 전용 디렉터리에 둔다. 사람이 쓰던 .terraform 에 backend 가 초기화돼 있으면
# -backend=false 라도 backend 를 읽으려고 자격 증명을 찾기 때문이다. make plan 은 이 디렉터리의 모듈로 plan 한다.
export TF_DATA_DIR=.terraform-gate

# HashiCorp 버전 확인(checkpoint) 외부 호출을 끈다. 버전은 고정해서 쓴다.
export CHECKPOINT_DISABLE=1

POLICY="$PWD/policy"
HASHES="$POLICY/module-hashes.txt"
OUTPUT="${GATE_OUTPUT:-stdout}"
CONFTEST=(conftest test --parser hcl2 --policy "$POLICY" --output "$OUTPUT")
[ "$OUTPUT" = github ] && CONFTEST+=(--github-hide-passed)

warn() {
  if [ "$OUTPUT" = github ]; then echo "::warning::$1"; else echo "WARN - $1"; fi
}

block() {
  if [ "$OUTPUT" = github ]; then echo "::error::$1"; else echo "FAIL - $1"; fi
  exit 1
}

# 파일의 backend·cloud 블록만 뽑는다. 파일이 없거나 블록이 없으면 [].
backend_of() {
  local rev=$1 file=$2 tmp
  tmp=$(mktemp --suffix=.tf)
  if git show "$rev:$file" >"$tmp" 2>/dev/null; then
    conftest parse --parser hcl2 "$tmp" |
      jq -cS '[.terraform[]? | {backend, cloud} | with_entries(select(.value != null)) | select(. != {})]'
  else
    echo '[]'
  fi
  rm -f "$tmp"
}

# ── 관문 0·1: 변경 감지 ──
if [ -n "${GATE_BASE:-}" ]; then
  echo "== 관문 0·1: 변경 감지 (기준 ${GATE_BASE:0:7})"
  changed=$(git diff --name-only "$GATE_BASE" HEAD)

  while IFS= read -r f; do
    case "$f" in
      .github/workflows/*)
        warn "[gate.workflow_changed] 워크플로 변경, 보안 리뷰 필요: $f" ;;
      *.terraform.lock.hcl)
        warn "[gate.lock_changed] lock 파일 변경, 보안 리뷰 필요: $f" ;;
      *.tf)
        [ "$(backend_of "$GATE_BASE" "$f")" = "$(backend_of HEAD "$f")" ] ||
          block "[gate.backend_changed] backend 블록 변경, plan 중단: $f" ;;
    esac
  done <<<"$changed"
fi

# ── 관문 2: .tf 정적 검사 ──
echo "== 관문 2: 정적 검사"

# Terraform 이 읽지만 이 검사가 보지 않는 파일은 받지 않는다.
# (.tf.json 은 hcl2 파서 대상이 아니고, 커밋된 .terraform/ 는 init 결과를 바꿔치기할 수 있다)
unscanned=$(git ls-files | grep -E '\.tf\.json$|(^|/)\.terraform(-gate)?/' || true)
[ -z "$unscanned" ] || block "[gate.unscanned_file] 검사하지 않는 Terraform 파일: $(echo $unscanned)"

find terraform -name '*.tf' -not -path '*/.terraform/*' -not -path '*/.terraform-gate/*' -print0 |
  xargs -0 "${CONFTEST[@]}"

# ── 관문 3·2b: root 마다 init 후 내려받은 모듈 검사 ──
for root in terraform/environments/*/; do
  root=${root%/}
  compgen -G "$root/*.tf" >/dev/null || continue

  echo "== 관문 3: $root init (lock 고정)"
  terraform -chdir="$root" init -backend=false -lockfile=readonly -input=false >/dev/null ||
    block "[gate.lock_mismatch] init 실패 (프로바이더 해시·버전이 lock 파일과 다름 등): $root"

  echo "== 관문 2b: $root 원격 모듈"
  modules="$root/$TF_DATA_DIR/modules/modules.json"
  [ -f "$modules" ] || continue

  # 원격 모듈만 $TF_DATA_DIR/modules 아래로 내려받는다. 로컬 경로 모듈은 관문 2에서 이미 봤다.
  while IFS=$'\t' read -r key source version dir; do
    [ -n "$key" ] || continue

    find "$root/$dir" -maxdepth 1 -name '*.tf' -print0 | xargs -0 -r "${CONFTEST[@]}"

    [ -z "$(find "$root/$dir" -maxdepth 1 -name '*.tf.json')" ] ||
      block "[gate.unscanned_file] 원격 모듈에 .tf.json: module.$key"

    hash=$(cd "$root/$dir" && find . -type f -not -path './.git/*' -print0 | sort -z |
      xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1)
    id="$root module.$key $source $version"
    expected=$(awk -v id="$id" '!/^#/ && NF {h=$NF; $NF=""; sub(/ $/, ""); if ($0 == id) print h}' "$HASHES")

    if [ -z "$expected" ]; then
      warn "기준 해시 없음 (새 모듈·버전 변경). 내용을 검토한 뒤 policy/module-hashes.txt 에 추가: $id $hash"
    elif [ "$expected" != "$hash" ]; then
      warn "[gate.module_content_changed] 같은 버전인데 모듈 내용이 다름: $id (기준 $expected, 현재 $hash)"
    fi
  done < <(jq -r --arg d "$TF_DATA_DIR/modules/" '.Modules[] | select(.Dir | startswith($d))
                  | [.Key, .Source, (.Version // "-"), .Dir] | @tsv' "$modules")
done

echo "== gate 통과"

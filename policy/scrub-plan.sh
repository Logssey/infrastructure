#!/usr/bin/env bash
# ─────────────────────────────────────────────
# IaC 보안 plan JSON 민감값 제거 (ADR-06)
#
# terraform show -json 결과에서 sensitive 로 표시된 값만 "(sensitive)" 로 바꾼다. 키와 구조는 그대로 둔다.
# 어떤 값이 sensitive 인지는 plan JSON 안의 표시를 따른다.
#
#   resource_changes·resource_drift   change.before·after       ← before_sensitive·after_sensitive
#   output_changes                    before·after              ← before_sensitive·after_sensitive
#   planned_values·prior_state        리소스 values             ← sensitive_values
#                                     outputs.value             ← sensitive
#   variables                         value                     ← configuration 의 변수 sensitive
#   configuration                     변수 default (하위 모듈 포함) ← sensitive
#
# 사용법: policy/scrub-plan.sh plan.json > plan.scrubbed.json
# ─────────────────────────────────────────────

set -euo pipefail

jq '
  # 키가 있을 때만 바꾼다. (없는 키에 null 을 만들지 않게)
  def upd(k; f): if type == "object" and has(k) then .[k] |= f else . end;

  # 값과 같은 모양의 표시($m)를 따라 내려가며 true 인 자리의 값을 지운다.
  def mask($m):
    if $m == true then "(sensitive)"
    elif ($m | type) == "object" and type == "object" then
      with_entries(.key as $k | if $m[$k] == null then . else .value |= mask($m[$k]) end)
    elif ($m | type) == "array" and type == "array" then
      [to_entries[] | .key as $i | .value | if $m[$i] == null then . else mask($m[$i]) end]
    else . end;

  def change:
    . as $c
    | upd("before"; mask($c.before_sensitive // false))
    | upd("after"; mask($c.after_sensitive // false));

  def module_values:
    upd("resources"; map(. as $r | upd("values"; mask($r.sensitive_values // {}))))
    | upd("child_modules"; map(module_values));

  def values:
    upd("outputs"; map_values(if .sensitive then upd("value"; "(sensitive)") else . end))
    | upd("root_module"; module_values);

  def config_module:
    upd("variables"; map_values(if .sensitive then upd("default"; "(sensitive)") else . end))
    | upd("module_calls"; map_values(upd("module"; config_module)));

  # 표시($m)가 true 인 자리의 문자열을 모두 꺼낸다.
  def secrets($m):
    if $m == true then .. | strings
    elif ($m | type) == "object" and type == "object" then
      . as $v | $m | keys[] as $k | $v[$k] // empty | secrets($m[$k])
    elif ($m | type) == "array" and type == "array" then
      . as $v | range(0; [($m | length), ($v | length)] | min) as $i | $v[$i] | secrets($m[$i])
    else empty end;

  [.configuration.root_module.variables // {} | to_entries[] | select(.value.sensitive) | .key] as $sensitive_vars

  # Terraform 은 민감값이 복사된 자리(프로바이더가 돌려준 속성 등)에 표시를 붙이지 않을 때가 있다.
  # 표시로 찾은 값을 모아 두었다가 마지막에 문서 전체에서 한 번 더 지운다.
  | ([ ((.resource_changes, .resource_drift)[]? | .change), .output_changes[]?
       | . as $c | ($c.before | secrets($c.before_sensitive)), ($c.after | secrets($c.after_sensitive)) ]
     + [ (.planned_values, .prior_state.values) | .. | objects | select(has("sensitive_values"))
         | . as $r | $r.values | secrets($r.sensitive_values) ]
     + [ (.planned_values, .prior_state.values) | .outputs[]? | select(.sensitive) | .value | .. | strings ]
     + [ .variables[$sensitive_vars[]]?.value | .. | strings ]
     | map(select(. != "")) | unique) as $secrets

  | upd("resource_changes"; map(upd("change"; change)))
  | upd("resource_drift"; map(upd("change"; change)))
  | upd("output_changes"; map_values(change))
  | upd("planned_values"; values)
  | upd("prior_state"; upd("values"; values))
  | upd("variables"; with_entries(if .key | IN($sensitive_vars[]) then .value |= upd("value"; "(sensitive)") else . end))
  | upd("configuration"; upd("root_module"; config_module))

  # 남은 값 중 민감값과 같거나(8자 이상이면) 민감값을 품은 문자열을 지운다. 키는 건드리지 않는다.
  | walk(if type == "string" and (. as $s | any($secrets[]; . as $x | $s == $x or (($x | length) >= 8 and ($s | contains($x)))))
         then "(sensitive)" else . end)
' "$1"

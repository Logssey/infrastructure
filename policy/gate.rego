# ─────────────────────────────────────────────
# IaC 보안 ② plan 전 검사 (gate)
#
# terraform init·plan 은 코드를 실행한다 (data "external" 등).
# 이 정책은 .tf 텍스트를 Conftest(hcl2 파서)로 읽어, 실행 구문과 공급망 위험을
# 자격 증명을 받기 전에 찾는다.
#
# 메시지는 "[<규칙 ID>] 설명" 형식이다. 규칙 ID·강도·심각도는
# security-solution-docs/iac-security/02-functional-design/rule-spec.md 와 같다.
#   deny = 차단, warn = 경고
#
# 실행: conftest test --parser hcl2 --policy policy terraform/
# 테스트: conftest verify --policy policy
# ─────────────────────────────────────────────

package main

import rego.v1

# 허용하는 프로바이더 (프로바이더 단위)
allowed_providers := {"hashicorp/aws"}

# plan 중에 임의 코드나 외부 통신을 실행하는 data 소스
exec_data_sources := {"external", "http", "dns"}

as_list(x) := x if is_array(x)

as_list(x) := [x] if not is_array(x)

# 레지스트리 주소 접두사를 떼고 소문자로 맞춘다.
normalize_source(s) := lower(trim_prefix(s, "registry.terraform.io/"))

# required_providers 의 각 항목 (이름, 설정)
required_provider_entry contains [pname, cfg] if {
	walk(input, [path, value])
	count(path) > 0
	path[count(path) - 1] == "required_providers"
	some rp in as_list(value)
	some pname, cfg in rp
	is_object(cfg)
}

# source 를 생략하면 hashicorp/<이름> 으로 본다 (Terraform 기본값).
provider_source(pname, cfg) := normalize_source(cfg.source)

provider_source(pname, cfg) := sprintf("hashicorp/%s", [lower(pname)]) if not cfg.source

# ── gate.exec_data_source (차단, CRITICAL) ──
deny contains msg if {
	some dtype in exec_data_sources
	some name, _ in input.data[dtype]
	msg := sprintf("[gate.exec_data_source] plan 중 실행되는 data 소스: data.%s.%s", [dtype, name])
}

# ── gate.provisioner (차단, CRITICAL) ──
# 파서 출력 구조와 무관하게 전체를 탐색한다.
deny contains msg if {
	walk(input, [path, _])
	count(path) > 0
	last := path[count(path) - 1]
	last in {"local-exec", "remote-exec"}
	msg := sprintf("[gate.provisioner] %s provisioner: %v", [last, array.slice(path, 0, 3)])
}

# ── gate.lambda_invocation (차단, HIGH) ──
deny contains msg if {
	some name, _ in input.data.aws_lambda_invocation
	msg := sprintf("[gate.lambda_invocation] plan 중 Lambda 호출: data.aws_lambda_invocation.%s", [name])
}

# ── gate.provider_not_allowed (차단, HIGH) ──
deny contains msg if {
	some [pname, cfg] in required_provider_entry
	src := provider_source(pname, cfg)
	not src in allowed_providers
	msg := sprintf("[gate.provider_not_allowed] 허용 목록 밖 프로바이더: %s (%s)", [pname, src])
}

# ── gate.provider_unpinned (경고, MEDIUM) ──
warn contains msg if {
	some [pname, cfg] in required_provider_entry
	not cfg.version
	msg := sprintf("[gate.provider_unpinned] 프로바이더 버전 미고정: %s", [pname])
}

# ── gate.module_unpinned (경고, MEDIUM) ──
# 로컬 경로(./, ../) 모듈은 대상이 아니다.
warn contains msg if {
	some mname, raw in input.module
	some b in as_list(raw)
	startswith(b.source, "git::")
	not contains(b.source, "?ref=")
	msg := sprintf("[gate.module_unpinned] git 모듈 ref 미고정: module.%s", [mname])
}

warn contains msg if {
	some mname, raw in input.module
	some b in as_list(raw)
	not startswith(b.source, ".")
	not startswith(b.source, "git::")
	not b.version
	msg := sprintf("[gate.module_unpinned] 레지스트리 모듈 version 없음: module.%s", [mname])
}

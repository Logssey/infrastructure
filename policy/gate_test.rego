# gate.rego 단위 테스트
#
# parse_config("hcl2", ...) 는 Conftest 가 실제 .tf 를 읽을 때와 같은 구조를 만든다.
# 위험 시나리오 S1~S6 은 IaC 보안 10/8 검증과 같다. S5(lock 해시 변경)는
# terraform init -lockfile=readonly 가 맡으므로 여기에 없다.

package main

import rego.v1

hits(set, rule_id) := [m | some m in set; startswith(m, sprintf("[%s]", [rule_id]))]

denied(tf, rule_id) if count(hits(deny, rule_id)) > 0 with input as parse_config("hcl2", tf)

warned(tf, rule_id) if count(hits(warn, rule_id)) > 0 with input as parse_config("hcl2", tf)

clean(tf) if {
	count(deny) == 0 with input as parse_config("hcl2", tf)
	count(warn) == 0 with input as parse_config("hcl2", tf)
}

# ── S1: plan 중 실행되는 data 소스 → 차단 ──

test_s1_external_denied if {
	denied(`data "external" "leak" { program = ["bash", "-c", "env"] }`, "gate.exec_data_source")
}

test_s1_http_denied if {
	denied(`data "http" "my_ip" { url = "https://ifconfig.me" }`, "gate.exec_data_source")
}

test_s1_dns_denied if {
	denied(`data "dns" "x" { host = "example.com" }`, "gate.exec_data_source")
}

# ── S2: provisioner → 차단 ──

test_s2_local_exec_denied if {
	denied(
		`
resource "null_resource" "x" {
  provisioner "local-exec" { command = "id" }
}`,
		"gate.provisioner",
	)
}

test_s2_remote_exec_denied if {
	denied(
		`
resource "aws_instance" "x" {
  provisioner "remote-exec" { inline = ["id"] }
}`,
		"gate.provisioner",
	)
}

# ── S3: 모듈 버전 미고정 → 경고 (규칙 명세 gate.module_unpinned) ──

test_s3_git_module_without_ref_warned if {
	warned(`module "net" { source = "git::https://github.com/example/tf-net.git" }`, "gate.module_unpinned")
}

test_s3_git_module_with_ref_clean if {
	clean(`module "net" { source = "git::https://github.com/example/tf-net.git?ref=v1.2.0" }`)
}

test_s3_registry_module_without_version_warned if {
	warned(`module "vpc" { source = "terraform-aws-modules/vpc/aws" }`, "gate.module_unpinned")
}

test_s3_registry_module_with_version_clean if {
	clean(`
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"
}`)
}

test_s3_local_module_clean if {
	clean(`module "iam" { source = "../../modules/iam" }`)
}

# ── S4: 허용 목록 밖 프로바이더 → 차단 ──

test_s4_typosquat_denied if {
	denied(
		`
terraform {
  required_providers {
    aws = { source = "hashlcorp/aws", version = "~> 6.65" }
  }
}`,
		"gate.provider_not_allowed",
	)
}

test_s4_other_hashicorp_provider_denied if {
	denied(
		`
terraform {
  required_providers {
    random = { source = "hashicorp/random", version = "3.6.0" }
  }
}`,
		"gate.provider_not_allowed",
	)
}

test_s4_registry_prefix_and_case_allowed if {
	clean(`
terraform {
  required_providers {
    aws = { source = "registry.terraform.io/HashiCorp/AWS", version = "~> 6.65" }
  }
}`)
}

test_s4_implicit_aws_source_allowed if {
	clean(`
terraform {
  required_providers {
    aws = { version = "~> 6.65" }
  }
}`)
}

test_provider_without_version_warned if {
	warned(
		`
terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}`,
		"gate.provider_unpinned",
	)
}

# ── Lambda 호출 → 차단 ──

test_lambda_invocation_data_denied if {
	denied(
		`
data "aws_lambda_invocation" "x" {
  function_name = "f"
  input         = "{}"
}`,
		"gate.lambda_invocation",
	)
}

# ── S6: 태그만 추가하는 정상 변경 → 통과 (오탐 확인) ──

test_s6_tag_only_change_clean if {
	clean(`
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.65" }
  }
}

resource "aws_instance" "web" {
  ami           = "ami-123"
  instance_type = "t3.micro"
  tags = {
    Name = "web"
    Team = "platform"
  }
}`)
}

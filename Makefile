# ─────────────────────────────────────────────
# IaC 로컬 래퍼
#
#   make plan            gate → 컨테이너에서 terraform plan (ENV=prod)
#   make gate            gate 만 (자격 증명 없음)
#   make tools           conftest·terraform 을 .tools/bin 에 설치 (체크섬 확인)
#
# CI(iac-gate 워크플로)와 같은 policy/gate.sh 를 먼저 돌려, 차단이면 자격 증명을 받기 전에 멈춘다.
# plan 은 홈 디렉터리가 없는 컨테이너에서, plan-ro Role 의 1시간짜리 읽기 전용 임시 키로 돌린다.
# 장기 키와 ~/.aws 는 컨테이너에 들어가지 않는다. (IaC 보안 ADR-12, 규칙 명세 운영 규칙)
# ─────────────────────────────────────────────

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

ENV ?= prod
ROOT := terraform/environments/$(ENV)
TOOLS := $(CURDIR)/.tools/bin

CONFTEST_VERSION := 0.71.1
CONFTEST_SHA256 := c3f6b2a753bd56e377a1e51a95ae3e057f926f2e9139f7d5b5dfbbaf810f7985
TERRAFORM_VERSION := 1.16.5
TERRAFORM_SHA256 := 2bc2fcfff033265c9e02ca0351f01794eb122f62a9b2a49a3294b9e49eaab5e4
TERRAFORM_IMAGE := hashicorp/terraform:1.16.5@sha256:c7926feace05d0f7e73542842bf3945924e955a1f782cf000ccbb8d18fa42d77

PLAN_ROLE := logssey-prod-role-iac-plan-ro

# terraform/ 는 gate 의 init 결과(.terraform-gate)까지 읽기 전용으로 넣는다.
# 임시 데이터 디렉터리에 모듈 목록을 복사하고 프로바이더는 링크해, gate 가 검사한 모듈·프로바이더로 plan 한다.
# backend 초기화도 그 임시 디렉터리에서 해서 사람이 쓰는 .terraform 은 건드리지 않는다.
PLAN_SCRIPT := mkdir /tmp/tfdata && cp -a .terraform-gate/modules /tmp/tfdata/ \
	&& ln -s "$$PWD/.terraform-gate/providers" /tmp/tfdata/providers \
	&& terraform init -lockfile=readonly >/dev/null && terraform plan -lock=false

DOCKER_RUN = docker run --rm \
	--user $$(id -u):$$(id -g) \
	--read-only --tmpfs /tmp \
	--cap-drop ALL --security-opt no-new-privileges \
	-e HOME=/tmp -e TF_DATA_DIR=/tmp/tfdata -e TF_IN_AUTOMATION=1 -e TF_INPUT=0 \
	-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
	-v "$(CURDIR)/terraform:/work/terraform:ro" \
	-w /work/$(ROOT) \
	--entrypoint sh $(TERRAFORM_IMAGE)

.PHONY: tools gate plan

tools: $(TOOLS)/conftest $(TOOLS)/terraform

$(TOOLS)/conftest:
	mkdir -p $(TOOLS) && tmp=$$(mktemp -d) && cd $$tmp && \
	curl -sSfLo c.tar.gz https://github.com/open-policy-agent/conftest/releases/download/v$(CONFTEST_VERSION)/conftest_$(CONFTEST_VERSION)_Linux_x86_64.tar.gz && \
	echo "$(CONFTEST_SHA256)  c.tar.gz" | sha256sum -c - && \
	tar xzf c.tar.gz conftest && install -m 0755 conftest $@ && rm -rf $$tmp

$(TOOLS)/terraform:
	mkdir -p $(TOOLS) && tmp=$$(mktemp -d) && cd $$tmp && \
	curl -sSfLo t.zip https://releases.hashicorp.com/terraform/$(TERRAFORM_VERSION)/terraform_$(TERRAFORM_VERSION)_linux_amd64.zip && \
	echo "$(TERRAFORM_SHA256)  t.zip" | sha256sum -c - && \
	unzip -q t.zip terraform && install -m 0755 terraform $@ && rm -rf $$tmp

gate: tools
	PATH="$(TOOLS):$$PATH" policy/gate.sh

plan: gate
	@account=$$(aws sts get-caller-identity --query Account --output text); \
	user=$$(aws sts get-caller-identity --query Arn --output text | awk -F/ '{print $$NF}'); \
	creds=$$(aws sts assume-role --role-arn "arn:aws:iam::$$account:role/$(PLAN_ROLE)" \
		--role-session-name "$$user" --duration-seconds 3600 --query Credentials --output json); \
	export AWS_ACCESS_KEY_ID=$$(jq -r .AccessKeyId <<<"$$creds"); \
	export AWS_SECRET_ACCESS_KEY=$$(jq -r .SecretAccessKey <<<"$$creds"); \
	export AWS_SESSION_TOKEN=$$(jq -r .SessionToken <<<"$$creds"); \
	echo "== plan ($(ENV), $(PLAN_ROLE)/$$user)"; \
	$(DOCKER_RUN) -c '$(PLAN_SCRIPT)'

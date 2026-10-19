# ─────────────────────────────────────────────
# scrub-plan.sh 테스트용 plan JSON(plan.json)을 만드는 설정
#
# 프로바이더 없이 내장 terraform_data 로 sensitive 값을 여러 모양으로 넣는다.
# (변수, 일부 속성, 리스트 원소, 값 전체, 바뀌는 값의 before·after, 출력)
# terraform_data 의 output 은 input 을 복사하지만 sensitive 표시가 없다 → 표시 없는 복사본도 지우는지 본다.
#
# 다시 만들기 (빈 디렉터리에 이 파일만 복사해서):
#   terraform init && terraform apply -auto-approve
#   terraform plan -var rotate=true -var db_password=FIXTURE-SECRET-var2 -out=tfplan
#   terraform show -json tfplan | jq . > plan.json
# 테스트는 FIXTURE-SECRET 이 하나도 남지 않는지 본다. 민감값은 모두 이 접두사로 시작해야 한다.
# ─────────────────────────────────────────────

variable "db_password" {
  type      = string
  sensitive = true
  default   = "FIXTURE-SECRET-var"
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

# 일부 속성만 sensitive: input 안의 password 만 표시되는지 본다
resource "terraform_data" "partial" {
  input = {
    username = "app"
    password = var.db_password
    tags     = ["a", sensitive("FIXTURE-SECRET-list")]
  }
}

# 값 전체가 sensitive
resource "terraform_data" "whole" {
  input = sensitive("FIXTURE-SECRET-whole")
}

# 이미 state 에 있고 바뀌는 리소스: before 쪽 마스킹 확인
resource "terraform_data" "changing" {
  input = { token = sensitive(var.rotate ? "FIXTURE-SECRET-new" : "FIXTURE-SECRET-old"), name = "keep" }
}

variable "rotate" {
  type    = bool
  default = false
}

output "secret_out" {
  value     = var.db_password
  sensitive = true
}

output "plain_out" {
  value = var.region
}

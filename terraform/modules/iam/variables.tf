variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "security_mode" {
  description = "permissive : 과다 권한 정책 부착 / strict : 최소 권한만"
  type        = string
}

variable "tfstate_bucket" {
  description = <<-EOT
    Terraform 상태 파일 버킷 이름.
    노드 Role 이 이 버킷에 접근하지 못하도록 Deny 정책을 생성한다.
  EOT
  type        = string
}

# ─────────────────────────────────────────────
# GitHub Actions OIDC
# ─────────────────────────────────────────────

variable "github_org" {
  description = "GitHub 조직 이름. 신뢰 정책의 sub 클레임에 사용한다."
  type        = string
  default     = "Logssey"
}

variable "github_repos" {
  description = <<-EOT
    이 Role 을 assume 할 수 있는 레포 목록.

    각 항목은 `repo:<org>/<repo>:ref:refs/heads/main` 으로 변환되어
    main 브랜치에서 실행된 워크플로만 허용한다.
  EOT
  type        = list(string)
  default     = ["reused-backend", "reused-frontend"]
}

variable "ecr_repository_arns" {
  description = <<-EOT
    GitHub Actions 가 push 할 수 있는 ECR 리포지토리 ARN 목록.
    ecr 모듈의 output 을 전달한다.
  EOT
  type        = list(string)
}

variable "region" {
  description = "AWS 리전. Secrets Manager ARN 범위 제한에 사용한다."
  type        = string
}
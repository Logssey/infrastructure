variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "repositories" {
  description = <<-EOT
    생성할 ECR 리포지토리 이름 목록.

    앞에 namespace 를 붙여 `logssey/reused-api` 형태가 된다.
    서비스 단위로 나눈다. 리포지토리 개수 자체는 과금되지 않으며
    저장 용량과 데이터 전송량으로만 계산된다.
  EOT
  type        = list(string)
  default     = ["reused-api", "reused-chat", "reused-web"]
}

variable "namespace" {
  description = "리포지토리 이름 접두사. logssey/reused-api 의 앞부분"
  type        = string
  default     = "logssey"
}

variable "image_tag_mutability" {
  description = <<-EOT
    같은 태그로 이미지를 덮어쓸 수 있는지.

    MUTABLE   : 덮어쓰기 가능
    IMMUTABLE : 같은 태그 재푸시 거부

    커밋 SHA 를 태그로 쓰므로 원칙적으로 덮어쓸 일이 없다.
    다만 IMMUTABLE 로 두면 재빌드 시 push 가 실패해
    CI 재실행이 막히므로 MUTABLE 을 유지한다.
  EOT
  type        = string
  default     = "MUTABLE"
}

variable "scan_on_push" {
  description = <<-EOT
    push 시 취약점 스캔 (ECR Basic scanning).

    무료이며 push 시점에 한 번 실행된다.
    지속 스캔이 필요하면 Enhanced scanning (Inspector) 으로 전환한다.
  EOT
  type        = bool
  default     = true
}

variable "untagged_expire_days" {
  description = <<-EOT
    태그 없는 이미지 보관 기간 (일).

    같은 태그로 새 이미지를 푸시하면 기존 이미지의 태그가 벗겨진다.
    쓸모가 없으므로 빠르게 정리한다.
  EOT
  type        = number
  default     = 1
}

variable "keep_image_count" {
  description = <<-EOT
    리포지토리당 유지할 이미지 개수.

    Argo CD 에서 이전 커밋으로 롤백할 때 해당 이미지가 남아 있어야 한다.
    20개면 최근 배포 20건까지 되돌릴 수 있다.
  EOT
  type        = number
  default     = 20
}
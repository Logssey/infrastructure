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

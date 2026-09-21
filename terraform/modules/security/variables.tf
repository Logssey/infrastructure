variable "name_prefix" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "vpc_id" {
  description = "SG를 생성할 VPC ID"
  type        = string
}

variable "security_mode" {
  description = <<-EOT
    permissive : 체인 규칙 + 0.0.0.0/0 개방 규칙을 함께 부착한다.
    strict     : 개방 규칙을 제거하고 체인 규칙만 남긴다.
  EOT
  type        = string
}

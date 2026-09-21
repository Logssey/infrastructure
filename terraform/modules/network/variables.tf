variable "name_prefix" {
  description = "리소스 이름 접두사. {project}-{environment} 형식으로 전달받는다."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Pod/Service CIDR와 겹치지 않아야 한다."
  type        = string
}

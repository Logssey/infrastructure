variable "name_prefix" {
  description = "리소스 이름 접두사. {project}-{environment} 형식으로 전달받는다."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Pod/Service CIDR와 겹치지 않아야 한다."
  type        = string
}

variable "azs" {
  description = "사용할 가용영역 목록. 서브넷 CIDR 목록과 순서가 대응한다."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public Subnet CIDR"
  type        = list(string)
}

variable "private_app_subnet_cidrs" {
  description = "Private-App Subnet CIDR"
  type        = list(string)
}

variable "private_etcd_subnet_cidrs" {
  description = "Private-Etcd Subnet CIDR"
  type        = list(string)
}

variable "private_data_subnet_cidrs" {
  description = "Private-Data Subnet CIDR"
  type        = list(string)
}

variable "region" {
  description = "AWS 리전. VPC Endpoint service_name 조립에 사용한다."
  type        = string
}
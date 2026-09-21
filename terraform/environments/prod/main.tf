locals {
  # 모든 리소스 이름의 접두사. 0절 네이밍 규칙 {project}-{env}-{resource}
  name_prefix = "${var.project}-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
}

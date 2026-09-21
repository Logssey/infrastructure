locals {
  # 모든 리소스 이름의 접두사. 네이밍 규칙 {project}-{env}-{resource}
  name_prefix = "${var.project}-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  region      = var.region
  vpc_cidr    = var.vpc_cidr
  azs         = var.azs

  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_etcd_subnet_cidrs = var.private_etcd_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
}

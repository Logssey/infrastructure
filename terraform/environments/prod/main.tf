locals {
  # 모든 리소스 이름의 접두사. 네이밍 규칙 {project}-{env}-{resource}
  name_prefix = "${var.project}-${var.environment}"
}

# ─────────────────────────────────────────────
# 기반 계층
# ─────────────────────────────────────────────

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

module "security" {
  source = "../../modules/security"

  name_prefix     = local.name_prefix
  vpc_id          = module.network.vpc_id
  security_mode   = var.security_mode
  envoy_node_port = var.envoy_node_port
}

module "iam" {
  source = "../../modules/iam"

  name_prefix    = local.name_prefix
  security_mode  = var.security_mode
  tfstate_bucket = var.tfstate_bucket
}

# ─────────────────────────────────────────────
# 컴퓨트 · 데이터 계층
# ─────────────────────────────────────────────

module "compute" {
  source = "../../modules/compute"

  name_prefix           = local.name_prefix
  azs                   = var.azs
  instance_profile_name = module.iam.node_instance_profile_name

  private_app_subnet_ids  = module.network.private_app_subnet_ids
  private_etcd_subnet_ids = module.network.private_etcd_subnet_ids

  control_plane_sg_id = module.security.control_plane_sg_id
  etcd_sg_id          = module.security.etcd_sg_id
  worker_sg_id        = module.security.worker_sg_id
  k8s_node_sg_id      = module.security.k8s_node_sg_id
  redis_sg_id         = module.security.redis_sg_id

  control_plane_private_ips = var.control_plane_private_ips
  etcd_private_ips          = var.etcd_private_ips
  worker_private_ips        = var.worker_private_ips
  redis_private_ip          = var.redis_private_ip
}

module "rds" {
  source = "../../modules/rds"

  name_prefix = local.name_prefix

  private_data_subnet_ids = module.network.private_data_subnet_ids
  rds_sg_id               = module.security.rds_sg_id

  engine_version         = var.rds_engine_version
  parameter_group_family = var.rds_parameter_group_family
  instance_class         = var.rds_instance_class
  multi_az               = var.rds_multi_az
}

# ─────────────────────────────────────────────
# 엣지 계층
#
# 의존 순서: dns → lb → edge
#   dns  : Hosted Zone, ACM 인증서
#   lb   : NLB (dns 의 origin 인증서 사용)
#   edge : CloudFront, WAF, 서비스 레코드 (dns·lb 참조)
#
# 모듈을 이 순서로 나눈 것은 순환 참조를 피하기 위함이다.
# ─────────────────────────────────────────────

module "dns" {
  source = "../../modules/dns"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = local.name_prefix
  domain_name = var.domain_name
}

module "lb" {
  source = "../../modules/lb"

  name_prefix = local.name_prefix
  vpc_id      = module.network.vpc_id

  private_app_subnet_ids = module.network.private_app_subnet_ids
  public_subnet_ids      = module.network.public_subnet_ids

  internal_nlb_sg_id = module.security.internal_nlb_sg_id
  public_nlb_sg_id   = module.security.public_nlb_sg_id

  control_plane_instance_ids = module.compute.control_plane_instance_ids
  worker_instance_ids        = module.compute.worker_instance_ids

  envoy_node_port = var.envoy_node_port

  origin_certificate_arn = module.dns.origin_certificate_arn
}

module "edge" {
  source = "../../modules/edge"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = local.name_prefix
  domain_name = var.domain_name

  zone_id         = module.dns.zone_id
  certificate_arn = module.dns.cloudfront_certificate_arn

  origin_domain       = "origin.${var.domain_name}"
  public_nlb_dns_name = module.lb.public_nlb_dns_name
  public_nlb_zone_id  = module.lb.public_nlb_zone_id

  waf_enabled = var.waf_enabled
  price_class = var.cloudfront_price_class
}
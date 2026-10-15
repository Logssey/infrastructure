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
  region         = var.region
  security_mode  = var.security_mode
  tfstate_bucket = var.tfstate_bucket

  # 로컬 make plan 에서 읽기 전용 plan-ro Role 을 쓸 IAM 사용자 (IaC 보안 ADR-12)
  iac_plan_local_users = ["jongmin"]

  ecr_repository_arns = module.ecr.repository_arns

  # 이미지 업로드와 Loki 로그 저장에 쓰는 버킷.
  # 여기 없는 버킷에는 노드 Role 로 접근할 수 없다.
  s3_bucket_arns = concat(
    [module.s3.image_bucket_arn],
    module.s3.loki_bucket_arns,
  )
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

# ─────────────────────────────────────────────
# 쿠버네티스 서비스 계정 OIDC (IRSA)
#
# jwks.json 은 cp 노드에서 `kubectl get --raw /openid/v1/jwks` 로 받은 공개 키다.
# 서명 키를 교체하면 이 파일을 다시 받는다.
# ─────────────────────────────────────────────

module "k8s_oidc" {
  source = "../../modules/k8s-oidc"

  name_prefix     = local.name_prefix
  domain_name     = var.domain_name
  zone_id         = module.dns.zone_id
  certificate_arn = module.dns.cloudfront_certificate_arn
  price_class     = var.cloudfront_price_class

  jwks_json = file("${path.module}/k8s-oidc/jwks.json")

  # 10/14 시험 완료(시험 파드가 이 Role 로 나옴). 시험 Role 은 지운다.
  create_irsa_test_role = false
}

# ─────────────────────────────────────────────
# CI/CD
# ─────────────────────────────────────────────

module "ecr" {
  source = "../../modules/ecr"

  name_prefix = local.name_prefix
}
# ─────────────────────────────────────────────
# S3
#
# 이미지 업로드 버킷은 콘솔에서 먼저 만들어진 것을 가져온다.
# imports.tf 참조.
# ─────────────────────────────────────────────

module "s3" {
  source = "../../modules/s3"

  name_prefix = local.name_prefix

  image_allowed_origins = [
    "https://${var.domain_name}",
    "https://www.${var.domain_name}",
  ]
}

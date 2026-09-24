output "control_plane_private_ips" {
  description = "Kubespray 인벤토리 [kube_control_plane]"
  value       = module.compute.control_plane_private_ips
}

output "etcd_private_ips" {
  description = "Kubespray 인벤토리 [etcd]"
  value       = module.compute.etcd_private_ips
}

output "worker_private_ips" {
  description = "Kubespray 인벤토리 [kube_node]"
  value       = module.compute.worker_private_ips
}

output "redis_private_ip" {
  value = module.compute.redis_private_ip
}

output "nat_gateway_public_ip" {
  description = "아웃바운드 출구 IP. 외부 서비스 허용목록 등록에 사용"
  value       = module.network.nat_gateway_public_ip
}

output "ami_id" {
  value = module.compute.ami_id
}

output "route53_name_servers" {
  description = "도메인 등록기관에 입력할 NS 레코드"
  value       = module.dns.name_servers
}

output "internal_api_dns_name" {
  description = "Kubespray inventory 의 loadbalancer_apiserver"
  value       = module.lb.internal_api_dns_name
}

output "public_nlb_dns_name" {
  description = "CloudFront Origin 대상"
  value       = module.lb.public_nlb_dns_name
}

output "internal_api_target_group_arn" {
  value = module.lb.internal_api_target_group_arn
}

output "public_target_group_arn" {
  value = module.lb.public_target_group_arn
}

output "control_plane_instance_ids" {
  description = "SSM 접속 대상. aws ssm start-session --target <id>"
  value       = module.compute.control_plane_instance_ids
}

output "worker_instance_ids" {
  value = module.compute.worker_instance_ids
}

output "etcd_instance_ids" {
  value = module.compute.etcd_instance_ids
}

output "redis_instance_id" {
  value = module.compute.redis_instance_id
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "route53_zone_id" {
  description = "Route53 레코드 추가 시 참조한다."
  value       = module.dns.zone_id
}

output "rds_endpoint" {
  description = "DB 엔드포인트 (host:port)"
  value       = module.rds.endpoint
}

output "rds_address" {
  description = "DB 호스트 주소"
  value       = module.rds.address
}

output "rds_instance_id" {
  value = module.rds.instance_id
}

output "rds_parameter_group_name" {
  value = module.rds.parameter_group_name
}

output "rds_master_user_secret_arn" {
  description = <<-EOT
    마스터 비밀번호가 저장된 Secrets Manager 시크릿 ARN.

    조회:
      aws secretsmanager get-secret-value \
        --secret-id $(terraform output -raw rds_master_user_secret_arn) \
        --region ap-northeast-1 --query 'SecretString' --output text
  EOT
  value       = module.rds.master_user_secret_arn
}

output "cloudfront_certificate_arn" {
  description = "CloudFront 용 ACM 인증서 ARN (us-east-1)"
  value       = module.dns.cloudfront_certificate_arn
}

output "origin_certificate_arn" {
  description = "Public NLB TLS 리스너용 ACM 인증서 ARN (ap-northeast-1)"
  value       = module.dns.origin_certificate_arn
}

output "public_nlb_arn" {
  value = module.lb.public_nlb_arn
}

output "public_nlb_zone_id" {
  description = "Route53 alias 레코드 생성에 필요하다."
  value       = module.lb.public_nlb_zone_id
}

output "cloudfront_distribution_id" {
  description = <<-EOT
    CloudFront Distribution ID.

    캐시 무효화:
      aws cloudfront create-invalidation \
        --distribution-id $(terraform output -raw cloudfront_distribution_id) \
        --paths "/*"
  EOT
  value       = module.edge.cloudfront_distribution_id
}

output "cloudfront_domain_name" {
  description = "CloudFront 기본 도메인"
  value       = module.edge.cloudfront_domain_name
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN. waf_enabled 가 false 면 null"
  value       = module.edge.waf_web_acl_arn
}

output "ecr_repository_urls" {
  description = "CI 워크플로에서 push 대상으로 사용한다."
  value       = module.ecr.repository_urls
}
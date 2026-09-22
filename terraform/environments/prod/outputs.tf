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
  value       = module.edge.name_servers
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
  value       = module.edge.zone_id
}
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

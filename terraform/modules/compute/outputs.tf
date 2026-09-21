output "control_plane_private_ips" {
  description = "Control Plane 사설 IP 목록"
  value       = aws_instance.control_plane[*].private_ip
}

output "etcd_private_ips" {
  description = "etcd 사설 IP 목록"
  value       = aws_instance.etcd[*].private_ip
}

output "worker_private_ips" {
  description = "Worker 사설 IP 목록"
  value       = aws_instance.worker[*].private_ip
}

output "redis_private_ip" {
  description = "Redis 사설 IP"
  value       = aws_instance.redis.private_ip
}

output "control_plane_instance_ids" {
  description = "Control Plane 인스턴스 ID. SSM 접속에 사용한다."
  value       = aws_instance.control_plane[*].id
}

output "worker_instance_ids" {
  value = aws_instance.worker[*].id
}

output "etcd_instance_ids" {
  value = aws_instance.etcd[*].id
}

output "redis_instance_id" {
  value = aws_instance.redis.id
}

output "ami_id" {
  description = "생성에 사용한 AMI ID. 문서 기록용"
  value       = local.ami_id
}

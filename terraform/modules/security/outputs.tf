output "public_nlb_sg_id" {
  value = aws_security_group.public_nlb.id
}

output "internal_nlb_sg_id" {
  value = aws_security_group.internal_nlb.id
}

output "control_plane_sg_id" {
  value = aws_security_group.control_plane.id
}

output "etcd_sg_id" {
  value = aws_security_group.etcd.id
}

output "worker_sg_id" {
  value = aws_security_group.worker.id
}

output "k8s_node_sg_id" {
  value = aws_security_group.k8s_node.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "redis_sg_id" {
  value = aws_security_group.redis.id
}

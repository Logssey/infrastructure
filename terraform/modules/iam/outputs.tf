output "node_instance_profile_name" {
  description = "EC2 인스턴스 프로파일 이름. compute 모듈에서 참조한다."
  value       = aws_iam_instance_profile.node.name
}

output "node_role_arn" {
  description = "노드 IAM Role ARN"
  value       = aws_iam_role.node.arn
}

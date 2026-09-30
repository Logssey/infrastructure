output "node_instance_profile_name" {
  description = "EC2 인스턴스 프로파일 이름. compute 모듈에서 참조한다."
  value       = aws_iam_instance_profile.node.name
}

output "node_role_arn" {
  description = "노드 IAM Role ARN"
  value       = aws_iam_role.node.arn
}

output "github_actions_role_arn" {
  description = <<-EOT
    GitHub Actions 워크플로의 role-to-assume 에 지정한다.
    레포 Secret 에 AWS_ROLE_ARN 으로 저장한다.
  EOT
  value       = aws_iam_role.github_actions.arn
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
output "instance_id" {
  description = "SSM 접속 대상"
  value       = aws_instance.host.id
}

output "private_ip" {
  value = aws_instance.host.private_ip
}

output "data_volume_id" {
  description = "6단계에서 디스크를 찾을 때 쓴다"
  value       = aws_ebs_volume.data.id
}

output "ecr_repository_urls" {
  value = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "dashboard_url" {
  value = "https://${local.dashboard_fqdn}"
}

output "deploy_role_arns" {
  description = "자동 배포 역할. dashboard-backend(api)·dashboard-frontend(frontend) 레포 변수 DASHBOARD_DEPLOY_ROLE_ARN 에 넣는다"
  value       = { for name, role in aws_iam_role.deploy : name => role.arn }
}

output "deploy_document" {
  value = aws_ssm_document.deploy.name
}

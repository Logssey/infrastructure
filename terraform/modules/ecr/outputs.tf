output "repository_urls" {
  description = <<-EOT
    리포지토리 URL 맵. CI 워크플로에서 push 대상으로 사용한다.

    예: { "reused-api" = "794386801311.dkr.ecr.ap-northeast-1.amazonaws.com/logssey/reused-api" }
  EOT
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "리포지토리 ARN 목록. IAM 정책의 Resource 에 사용한다."
  value       = [for v in aws_ecr_repository.this : v.arn]
}

output "registry_id" {
  description = "ECR 레지스트리 ID (AWS 계정 ID)"
  value       = values(aws_ecr_repository.this)[0].registry_id
}
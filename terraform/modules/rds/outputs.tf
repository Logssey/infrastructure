output "endpoint" {
  description = "DB 엔드포인트 (host:port)"
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "DB 호스트 주소. 애플리케이션 연결 문자열에 사용한다."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "master_username" {
  value = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = <<-EOT
    마스터 비밀번호가 저장된 Secrets Manager 시크릿 ARN.

    조회:
      aws secretsmanager get-secret-value --secret-id <arn> \
        --region ap-northeast-1 --query 'SecretString' --output text
  EOT
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "instance_id" {
  description = "DB 인스턴스 식별자. CLI 조회에 사용한다."
  value       = aws_db_instance.this.identifier
}

output "parameter_group_name" {
  description = "파라미터 그룹 이름. 파라미터 확인에 사용한다."
  value       = aws_db_parameter_group.this.name
}

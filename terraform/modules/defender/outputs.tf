output "cspm_role_arn" {
  description = "Defender for Cloud 커넥터가 assume 하는 CSPM Role ARN"
  value       = aws_iam_role.cspm_monitor.arn
}

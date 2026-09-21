output "internal_api_dns_name" {
  description = "Kubespray inventory 의 loadbalancer_apiserver 에 지정한다."
  value       = aws_lb.internal_api.dns_name
}

output "internal_api_arn" {
  value = aws_lb.internal_api.arn
}

output "internal_api_target_group_arn" {
  description = "타겟 상태 확인에 사용한다."
  value       = aws_lb_target_group.internal_api.arn
}

output "public_nlb_dns_name" {
  description = "CloudFront Origin 및 origin 레코드 대상"
  value       = aws_lb.public.dns_name
}

output "public_nlb_arn" {
  value = aws_lb.public.arn
}

output "public_nlb_zone_id" {
  description = "Route53 alias 레코드 생성에 필요하다."
  value       = aws_lb.public.zone_id
}

output "public_target_group_arn" {
  value = aws_lb_target_group.public.arn
}

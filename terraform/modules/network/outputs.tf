output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public Subnet ID 목록"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Private-App Subnet ID 목록"
  value       = aws_subnet.private_app[*].id
}

output "private_etcd_subnet_ids" {
  description = "Private-Etcd Subnet ID 목록"
  value       = aws_subnet.private_etcd[*].id
}

output "private_data_subnet_ids" {
  description = "Private-Data Subnet ID 목록"
  value       = aws_subnet.private_data[*].id
}

output "private_app_route_table_id" {
  description = <<-EOT
    Private-App Route Table ID.
    Interface Endpoint 추가 시 라우팅 대상으로 참조한다.
  EOT
  value       = aws_route_table.private_app.id
}

output "private_etcd_route_table_id" {
  description = <<-EOT
    Private-Etcd Route Table ID.
    etcd 계층의 NAT 경로를 제거하고 Interface Endpoint 로 전환할 때 참조한다.
  EOT
  value       = aws_route_table.private_etcd.id
}

output "nat_gateway_public_ip" {
  description = "NAT Gateway 퍼블릭 IP. 외부 서비스 IP 허용목록 등록에 사용한다."
  value       = aws_eip.nat.public_ip
}

output "s3_vpc_endpoint_id" {
  description = <<-EOT
    S3 Gateway Endpoint ID.
    Endpoint Policy 를 부착해 접근 가능한 버킷을 제한할 때 참조한다.
  EOT
  value       = aws_vpc_endpoint.s3.id
}
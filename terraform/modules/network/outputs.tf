output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = aws_vpc.this.cidr_block
}

output "igw_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.this.id
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
  description = "Private-App Route Table ID"
  value       = aws_route_table.private_app.id
}

output "private_etcd_route_table_id" {
  description = "Private-Etcd Route Table ID"
  value       = aws_route_table.private_etcd.id
}

output "nat_gateway_public_ip" {
  description = "NAT Gateway 퍼블릭 IP. 외부 서비스 IP 허용목록 등록에 사용한다."
  value       = aws_eip.nat.public_ip
}

output "s3_vpc_endpoint_id" {
  description = "S3 Gateway Endpoint ID"
  value       = aws_vpc_endpoint.s3.id
}

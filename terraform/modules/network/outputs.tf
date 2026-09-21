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

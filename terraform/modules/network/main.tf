# ─────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # 둘 다 켜야 EC2에 내부 DNS 이름이 부여되고
  # RDS 엔드포인트가 VPC 안에서 해석된다. 기본값은 false다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# ─────────────────────────────────────────────
# Internet Gateway
# ─────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

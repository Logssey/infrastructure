# ─────────────────────────────────────────────
# Public Subnet
#   Public NLB, NAT Gateway 배치
# ─────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  # 이 서브넷에 생성되는 인스턴스에 퍼블릭 IP를 자동 할당하지 않는다.
  # NAT Gateway와 NLB는 명시적으로 EIP를 붙이므로 불필요하다.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-subnet-public-${local.az_suffix[count.index]}"
    Tier = "public"
  }
}

# ─────────────────────────────────────────────
# Private-App Subnet
#   Control Plane, Worker, Redis, Internal NLB 배치
# ─────────────────────────────────────────────

resource "aws_subnet" "private_app" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-subnet-app-${local.az_suffix[count.index]}"
    Tier = "private-app"
  }
}

# ─────────────────────────────────────────────
# Private-Etcd Subnet
#   external etcd 전용. 접근 통제는 Security Group이 담당한다.
# ─────────────────────────────────────────────

resource "aws_subnet" "private_etcd" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_etcd_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-subnet-etcd-${local.az_suffix[count.index]}"
    Tier = "private-etcd"
  }
}

# ─────────────────────────────────────────────
# Private-Data Subnet
#   RDS Subnet Group 전용. 인터넷 기본 경로를 두지 않는다.
# ─────────────────────────────────────────────

resource "aws_subnet" "private_data" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_data_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-subnet-data-${local.az_suffix[count.index]}"
    Tier = "private-data"
  }
}

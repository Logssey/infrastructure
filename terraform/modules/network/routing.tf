# ─────────────────────────────────────────────
# NAT Gateway
#   비용 절감을 위해 AZ-a에 1개만 배치한다.
#   AZ-a 장애 시 전 AZ의 아웃바운드가 차단되는 트레이드오프가 있다.
# ─────────────────────────────────────────────

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-eip-nat-${local.az_suffix[0]}"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  # IGW가 먼저 존재해야 NAT Gateway가 정상 동작한다.
  # 암묵적 의존성이 없으므로 명시한다.
  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${var.name_prefix}-nat-${local.az_suffix[0]}"
  }
}

# ─────────────────────────────────────────────
# Route Table : Public
# ─────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(var.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ─────────────────────────────────────────────
# Route Table : Private-App
#   3개 AZ가 AZ-a의 NAT Gateway를 공유한다.
#   AZ 간 전송료가 GB당 $0.01 발생하나 트래픽 규모상 무시할 수준이다.
# ─────────────────────────────────────────────

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-app"
  }
}

resource "aws_route" "private_app_nat" {
  route_table_id         = aws_route_table.private_app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private_app" {
  count = length(var.azs)

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app.id
}

# ─────────────────────────────────────────────
# Route Table : Private-Etcd
#   Kubespray 설치 시 OS 패키지·etcd 바이너리 다운로드가 필요하다.
#   설치 완료 후에는 아웃바운드가 발생하지 않으므로 경로 제거를 검토한다.
#   제거 시 SSM 접속을 위해 Interface Endpoint 3종이 필요하다.
# ─────────────────────────────────────────────

resource "aws_route_table" "private_etcd" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-etcd"
  }
}

resource "aws_route" "private_etcd_nat" {
  route_table_id         = aws_route_table.private_etcd.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private_etcd" {
  count = length(var.azs)

  subnet_id      = aws_subnet.private_etcd[count.index].id
  route_table_id = aws_route_table.private_etcd.id
}

# ─────────────────────────────────────────────
# Route Table : Private-Data
#   기본 경로를 두지 않는다. RDS는 인터넷에서 도달 불가능하며
#   RDS가 외부로 나가는 경로도 존재하지 않는다.
# ─────────────────────────────────────────────

resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-data"
  }
}

resource "aws_route_table_association" "private_data" {
  count = length(var.azs)

  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private_data.id
}

# ─────────────────────────────────────────────
# S3 Gateway Endpoint
#   Interface Endpoint와 달리 시간당 요금이 없다.
#   라우팅 테이블에 S3 Prefix List 경로가 추가되는 방식으로 동작하며
#   Security Group이 아니라 Endpoint Policy와 Bucket Policy로 통제한다.
# ─────────────────────────────────────────────

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  # 연결된 라우팅 테이블에 S3 Prefix List 경로가 자동 추가된다.
  # Private-Data는 제외한다. RDS는 S3에 접근할 필요가 없다.
  route_table_ids = [
    aws_route_table.private_app.id,
    aws_route_table.private_etcd.id,
  ]

  tags = {
    Name = "${var.name_prefix}-vpce-s3"
  }
}

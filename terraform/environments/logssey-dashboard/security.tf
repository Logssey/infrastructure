# 인바운드 규칙 없음. 사람은 SSM 포트 포워딩으로만 들어온다.
# VPC DNS(Route 53 Resolver)와 시간 동기화는 보안 그룹이 거르지 않는다.
resource "aws_security_group" "host" {
  name        = "${local.name_prefix}-sg-host"
  description = "Logssey dashboard host. No inbound, access through SSM only."
  vpc_id      = data.aws_vpc.service.id

  tags = {
    Name = "${local.name_prefix}-sg-host"
  }
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.host.id
  description       = "SSM, ECR, Docker Hub, package signatures"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.host.id
  description       = "Ubuntu package mirror"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}
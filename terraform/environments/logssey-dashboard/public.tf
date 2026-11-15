# ─────────────────────────────────────────────
# 인터넷 공개 (ADR-D010 개정): ALB(HTTPS) → EC2 의 frontend(nginx) → api.
# 로그인은 앱이 GitHub(조직원만)로 받는다. 호스트는 ALB 에서 오는 frontend_port 만 받는다.
# SSM 포트 포워딩(localhost:8088)은 비상 통로로 남긴다.
# ─────────────────────────────────────────────

locals {
  dashboard_fqdn = "${var.dashboard_host}.${var.service_domain}"
}

data "aws_route53_zone" "service" {
  name         = var.service_domain
  private_zone = false
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.service.id]
  }

  filter {
    name   = "tag:Name"
    values = var.public_subnet_names
  }
}

# ── 인증서 (도쿄 리전, DNS 검증) ──

resource "aws_acm_certificate" "dashboard" {
  domain_name       = local.dashboard_fqdn
  validation_method = "DNS"

  tags = {
    Name = "${local.name_prefix}-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.dashboard.domain_validation_options : o.domain_name => o
  }

  zone_id = data.aws_route53_zone.service.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "dashboard" {
  certificate_arn         = aws_acm_certificate.dashboard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ── 보안 그룹: 인터넷 → ALB 443·80, ALB → 호스트 frontend_port ──

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-sg-alb"
  description = "Logssey dashboard ALB. HTTPS from the internet, forwards to the dashboard frontend only."
  vpc_id      = data.aws_vpc.service.id

  tags = {
    Name = "${local.name_prefix}-sg-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP, redirected to HTTPS"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To the dashboard frontend on the host"
  ip_protocol                  = "tcp"
  from_port                    = var.frontend_port
  to_port                      = var.frontend_port
  referenced_security_group_id = aws_security_group.host.id
}

resource "aws_vpc_security_group_ingress_rule" "host_from_alb" {
  security_group_id            = aws_security_group.host.id
  description                  = "Dashboard frontend from the ALB only"
  ip_protocol                  = "tcp"
  from_port                    = var.frontend_port
  to_port                      = var.frontend_port
  referenced_security_group_id = aws_security_group.alb.id
}

# ── ALB ──

resource "aws_lb" "dashboard" {
  name                       = "${local.name_prefix}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = data.aws_subnets.public.ids
  drop_invalid_header_fields = true

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "frontend" {
  name        = "${local.name_prefix}-tg-frontend"
  port        = var.frontend_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.service.id
  target_type = "instance"

  # frontend nginx 의 상태 확인 경로 (로그인 없이 200)
  health_check {
    path    = "/healthz"
    matcher = "200"
  }

  tags = {
    Name = "${local.name_prefix}-tg-frontend"
  }
}

resource "aws_lb_target_group_attachment" "host" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.host.id
  port             = var.frontend_port
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.dashboard.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.dashboard.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.dashboard.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ── 주소 ──

resource "aws_route53_record" "dashboard" {
  zone_id = data.aws_route53_zone.service.zone_id
  name    = local.dashboard_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.dashboard.dns_name
    zone_id                = aws_lb.dashboard.zone_id
    evaluate_target_health = true
  }
}

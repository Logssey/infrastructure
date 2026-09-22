# ─────────────────────────────────────────────
# Internal API NLB
#
# kube-apiserver 앞단. kubelet / kubectl 이 이 주소로 접속한다.
# Kubespray inventory 의 loadbalancer_apiserver 에 지정한다.
#
# 주의: Security Group 은 생성 시점에만 지정할 수 있다.
#       SG 없이 만들면 이후 추가가 불가능해 NLB 를 재생성해야 한다.
#       연결된 SG 의 규칙 변경이나 SG 교체는 생성 후에도 가능하다.
# ─────────────────────────────────────────────

resource "aws_lb" "internal_api" {
  name               = "${var.name_prefix}-nlb-internal-api"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_app_subnet_ids
  security_groups    = [var.internal_nlb_sg_id]

  # NLB 는 기본이 비활성이다. AZ 마다 Control Plane 이 1대씩이므로
  # 비활성 상태에서 한 대가 죽으면 해당 AZ 트래픽이 전부 실패한다.
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.name_prefix}-nlb-internal-api"
  }
}

resource "aws_lb_target_group" "internal_api" {
  name        = "${var.name_prefix}-tg-api"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # 주의: 반드시 false 여야 한다.
  #
  # Control Plane 노드 자신도 이 NLB 를 경유해 apiserver 를 호출한다.
  # true 이면 NLB 가 클라이언트 IP 를 보존한 채 타겟에 전달하는데,
  # 요청이 발신 노드 자신에게 라우팅되면 출발지와 목적지가 같아져
  # TCP 연결이 성립하지 않는다. (hairpin)
  #
  # 3대 중 1대에 걸릴 때만 발생하므로 간헐적 타임아웃으로 나타나
  # 원인 추적이 매우 어렵다. Kubespray + NLB 조합의 대표적 장애 사례다.
  preserve_client_ip = false

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.name_prefix}-tg-api"
  }
}

resource "aws_lb_target_group_attachment" "internal_api" {
  count = length(var.control_plane_instance_ids)

  target_group_arn = aws_lb_target_group.internal_api.arn
  target_id        = var.control_plane_instance_ids[count.index]
  port             = 6443
}

resource "aws_lb_listener" "internal_api" {
  load_balancer_arn = aws_lb.internal_api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.internal_api.arn
  }
}

# ─────────────────────────────────────────────
# Public NLB
#
# CloudFront → Public NLB → Worker Node : Envoy NodePort
#
# 현재는 TCP 80 리스너만 구성되어 있다.
# TLS 443 리스너는 ACM 인증서 발급 후 추가한다.
# 리스너 추가는 NLB 재생성을 유발하지 않는다.
# ─────────────────────────────────────────────

resource "aws_lb" "public" {
  name               = "${var.name_prefix}-nlb-public"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  security_groups    = [var.public_nlb_sg_id]

  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.name_prefix}-nlb-public"
  }
}

resource "aws_lb_target_group" "public" {
  name        = "${var.name_prefix}-tg-envoy"
  port        = var.envoy_node_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # 주의: 반드시 false 여야 한다.
  #
  # true 인 상태에서는 Worker Node 가 보는 출발지 IP 가 NLB 가 아니라
  # 원래 클라이언트(CloudFront) IP 가 된다.
  # 그러면 sg-public-nlb → sg-worker 형태의 SG 참조 규칙이 동작하지 않는다.
  #
  # 실제 클라이언트 IP 는 CloudFront 가 X-Forwarded-For 로 전달하므로
  # Envoy Gateway 에서 읽는다.
  preserve_client_ip = false

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.name_prefix}-tg-envoy"
  }
}

resource "aws_lb_target_group_attachment" "public" {
  count = length(var.worker_instance_ids)

  target_group_arn = aws_lb_target_group.public.arn
  target_id        = var.worker_instance_ids[count.index]
  port             = var.envoy_node_port
}

resource "aws_lb_listener" "public_tcp" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.public.arn
  }
}

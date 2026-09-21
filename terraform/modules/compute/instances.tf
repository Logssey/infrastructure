# ─────────────────────────────────────────────
# 공통 설정
#
# IMDS: 1차 구축에서는 IMDSv1을 허용한다. (T2에서 required 로 전환)
#       Self-managed 클러스터에는 IRSA 가 없어 Pod 가 IMDS 로 노드 Role 자격증명에 접근할 수 있다.
#       hop_limit 을 1로 낮추면 컨테이너에서 도달하지 못한다.
#
# EBS:  암호화는 1차부터 활성화한다. 사후 적용이 불가능해 조치하려면 인스턴스 교체가 필요하기 때문이다.
#
# AMI:  ForceNew 속성이므로 ignore_changes 로 고정한다.
#       Canonical 이 새 AMI 를 게시해도 재생성되지 않는다.
# ─────────────────────────────────────────────

# ── Control Plane ──

resource "aws_instance" "control_plane" {
  count = length(var.azs)

  ami           = local.ami_id
  instance_type = var.control_plane_instance_type
  subnet_id     = var.private_app_subnet_ids[count.index]
  private_ip    = var.control_plane_private_ips[count.index]

  vpc_security_group_ids = [
    var.control_plane_sg_id,
    var.k8s_node_sg_id,
  ]

  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false
  user_data                   = local.k8s_node_user_data

  root_block_device {
    volume_type = "gp3"
    volume_size = var.control_plane_volume_size
    encrypted   = true

    tags = {
      Name = "${var.name_prefix}-ebs-cp-${local.az_suffix[count.index]}"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.imds_tokens
    http_put_response_hop_limit = var.imds_hop_limit
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.name_prefix}-cp-${local.az_suffix[count.index]}"
    Role = "control-plane"
  }
}

# ── external etcd ──

resource "aws_instance" "etcd" {
  count = length(var.azs)

  ami           = local.ami_id
  instance_type = var.etcd_instance_type
  subnet_id     = var.private_etcd_subnet_ids[count.index]
  private_ip    = var.etcd_private_ips[count.index]

  vpc_security_group_ids = [
    var.etcd_sg_id,
    var.k8s_node_sg_id,
  ]

  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false
  user_data                   = local.k8s_node_user_data

  root_block_device {
    volume_type = "gp3"
    volume_size = var.etcd_volume_size
    encrypted   = true

    tags = {
      Name = "${var.name_prefix}-ebs-etcd-${local.az_suffix[count.index]}"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.imds_tokens
    http_put_response_hop_limit = var.imds_hop_limit
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.name_prefix}-etcd-${local.az_suffix[count.index]}"
    Role = "etcd"
  }
}

# ── Worker ──

resource "aws_instance" "worker" {
  count = length(var.azs)

  ami           = local.ami_id
  instance_type = var.worker_instance_type
  subnet_id     = var.private_app_subnet_ids[count.index]
  private_ip    = var.worker_private_ips[count.index]

  vpc_security_group_ids = [
    var.worker_sg_id,
    var.k8s_node_sg_id,
  ]

  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false
  user_data                   = local.k8s_node_user_data

  root_block_device {
    volume_type = "gp3"
    volume_size = var.worker_volume_size
    encrypted   = true

    tags = {
      Name = "${var.name_prefix}-ebs-worker-${local.az_suffix[count.index]}"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.imds_tokens
    http_put_response_hop_limit = var.imds_hop_limit
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.name_prefix}-worker-${local.az_suffix[count.index]}"
    Role = "worker"
  }
}

# ── Redis (클러스터 외부) ──

resource "aws_instance" "redis" {
  ami           = local.ami_id
  instance_type = var.redis_instance_type
  subnet_id     = var.private_app_subnet_ids[0]
  private_ip    = var.redis_private_ip

  # k8s_node_sg 를 부착하지 않는다. 클러스터 구성원이 아니다.
  vpc_security_group_ids = [var.redis_sg_id]

  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false
  user_data                   = local.redis_user_data

  root_block_device {
    volume_type = "gp3"
    volume_size = var.redis_volume_size
    encrypted   = true

    tags = {
      Name = "${var.name_prefix}-ebs-redis-${local.az_suffix[0]}"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.imds_tokens
    http_put_response_hop_limit = var.imds_hop_limit
  }

  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${var.name_prefix}-redis-${local.az_suffix[0]}"
    Role = "redis"
  }
}

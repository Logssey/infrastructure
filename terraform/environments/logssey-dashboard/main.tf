locals {
  name_prefix  = "${var.project}-${var.environment}" # logssey-dashboard
  ami_id       = nonsensitive(data.aws_ssm_parameter.ubuntu_2404.value)
  ecr_registry = split("/", aws_ecr_repository.this["dashboard-api"].repository_url)[0]
}

# ─────────────────────────────────────────────
# 감시 대상 서비스의 네트워크를 이름 태그로 찾는다 (prod 상태를 읽지 않는다).
# ─────────────────────────────────────────────

data "aws_vpc" "service" {
  filter {
    name   = "tag:Name"
    values = [var.service_vpc_name]
  }
}

data "aws_subnet" "host" {
  vpc_id = data.aws_vpc.service.id

  filter {
    name   = "tag:Name"
    values = [var.subnet_name]
  }
}

# prod compute 모듈과 같은 Canonical 공개 파라미터
data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ─────────────────────────────────────────────
# 호스트. 공인 IP 없음, IMDSv2 필수, hop 1 (컨테이너는 IMDS 에 닿지 못한다).
# ─────────────────────────────────────────────

resource "aws_instance" "host" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.host.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/host-init.sh.tftpl", {
    ecr_registry = local.ecr_registry
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${local.name_prefix}-host"
  }

  # AMI 가 갱신되거나 첫 부팅 스크립트를 고쳐도 인스턴스를 다시 만들지 않는다.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# ─────────────────────────────────────────────
# PostgreSQL 데이터 디스크. 인스턴스와 따로 두어 인스턴스를 바꿔도 데이터가 남는다.
# ─────────────────────────────────────────────

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.host.availability_zone
  type              = "gp3"
  size              = var.data_volume_size
  encrypted         = true

  tags = {
    Name     = "${local.name_prefix}-data"
    Snapshot = "${local.name_prefix}-data" # backup.tf 의 스냅샷 대상 표시
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.host.id
}
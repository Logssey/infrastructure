# ─────────────────────────────────────────────
# EC2 노드 공통 IAM Role
#
# 1차 구축에서는 CP / etcd / Worker / Redis 10대에 동일한 Role 을 부착한다.
# 역할별 최소 권한 분리는 T2 조치 항목이다.
#
# Self-managed 클러스터에는 IRSA 가 없으므로 노드 위의 모든 Pod 가
# IMDS 를 통해 이 Role 의 권한을 사용할 수 있다. 구조적 한계이며
# IMDSv2 강제와 hop limit 제한으로 완화한다. (T2)
# ─────────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-role-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name = "${var.name_prefix}-role-node"
  }
}

# SSM Session Manager 접속에 필요하다.
# 인바운드 포트를 열지 않는 구성이므로 SSM 이 유일한 접근 경로다.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR 이미지 pull. T2 에서 Worker 전용 Role 로 분리한다.
resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# EBS CSI Driver 볼륨 관리.
#
# permissive 모드의 AmazonEC2FullAccess 로도 동작하나,
# strict 전환 시 해당 정책이 제거되면 PVC 프로비저닝이 중단된다.
# 최소 권한 정책을 별도로 부착해 모드와 무관하게 유지한다.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ─────────────────────────────────────────────
# 상태 파일 버킷 보호 — 모드 무관, 항상 적용
#
# 상태 파일에는 RDS·Redis 비밀번호가 평문으로 저장되므로 의도적 취약 설정의 범위에서 제외한다.
# IAM 평가에서 Deny 는 Allow 보다 우선하므로 AmazonS3FullAccess 가 부착되어 있어도 이 버킷에는 접근할 수 없다.
# ─────────────────────────────────────────────

resource "aws_iam_role_policy" "deny_tfstate" {
  name = "${var.name_prefix}-deny-tfstate"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Deny"
      Action = "s3:*"
      Resource = [
        "arn:aws:s3:::${var.tfstate_bucket}",
        "arn:aws:s3:::${var.tfstate_bucket}/*"
      ]
    }]
  })
}

# ─────────────────────────────────────────────
# 인스턴스 프로파일
#   EC2 에 Role 을 부착하려면 프로파일로 감싸야 한다.
# ─────────────────────────────────────────────

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-instance-profile-node"
  role = aws_iam_role.node.name

  tags = {
    Name = "${var.name_prefix}-instance-profile-node"
  }
}

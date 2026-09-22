# ─────────────────────────────────────────────
# permissive 모드 전용 과다 권한 정책
#
# security_mode = "strict" 로 바꾸면 제거된다.
#
# 예상 finding:
#   - Overly permissive IAM policy attached to EC2 role
#   - IAM policy allows full access to service
# ─────────────────────────────────────────────

locals {
  permissive = var.security_mode == "permissive" ? 1 : 0
}

# 실제 필요 범위: 이미지 버킷 Get/Put, 감사 버킷 Put
# tfstate 버킷은 main.tf 의 Deny 정책으로 차단된다.
resource "aws_iam_role_policy_attachment" "open_s3_full" {
  count = local.permissive

  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# EC2 전체 권한.
#
# EBS CSI Driver 가 필요로 하는 권한은 main.tf 의
# AmazonEBSCSIDriverPolicy 로 이미 충족된다.
# 이 정책은 finding 생성 외에 실제 용도가 없으며 strict 에서 제거된다.
resource "aws_iam_role_policy_attachment" "open_ec2_full" {
  count = local.permissive

  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

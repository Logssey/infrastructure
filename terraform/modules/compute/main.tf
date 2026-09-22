# ─────────────────────────────────────────────
# AMI
#   Canonical이 SSM Public Parameter로 제공한다.
#   ami 속성은 ForceNew이므로 각 인스턴스에 lifecycle { ignore_changes = [ami] } 를 적용한다.
#
#   aws_ssm_parameter 의 value 는 SecureString 가능성 때문에 provider 가 일괄 sensitive 로 표시한다. 
#   이 파라미터는 AWS 가 공개하는 AMI ID 이므로 nonsensitive() 로 해제한다.
# ─────────────────────────────────────────────

data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  ami_id = nonsensitive(data.aws_ssm_parameter.ubuntu_2404.value)

  k8s_node_user_data = file("${path.module}/templates/k8s-node.sh")
  redis_user_data    = file("${path.module}/templates/redis.sh")

  az_suffix = [for az in var.azs : substr(az, -1, 1)]
}

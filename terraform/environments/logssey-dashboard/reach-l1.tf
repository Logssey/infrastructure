# ─────────────────────────────────────────────
# Reach L1 수집기 이미지 (dashboard-backend deploy/reach/l1-collector).
#
# 수집기는 Re:Used 클러스터의 CronJob(gitops reach/l1/)으로 돌며, 실행 중인 파드의 이미지 digest 를
# 이 대시보드(PUT /api/v1/reach/l1/workloads)로 보낸다. 클러스터 노드 역할의 ECR 읽기(AmazonEC2ContainerRegistryReadOnly)로 받는다.
# 대시보드 호스트는 이 이미지를 받지 않으므로 host_ecr_pull 에 넣지 않는다.
# 태그를 바꿀 수 없게 하고, CronJob 에는 digest 로 고정한다. 태그 없는 이미지를 지우는 규칙이 없어 고정한 digest 가 사라지지 않는다.
# ─────────────────────────────────────────────

resource "aws_ecr_repository" "reach_l1_collector" {
  name                 = "${var.project}/reach-l1-collector"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "reach_l1_collector" {
  repository = aws_ecr_repository.reach_l1_collector.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

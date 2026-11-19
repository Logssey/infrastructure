# 태그를 바꿀 수 없게 하고, compose 에는 digest 로 고정한다.
# dashboard-secret-worker: dashboard-backend 의 Secret 워커(Dockerfile --target worker). API 와 같은 커밋으로 만든다.
# dashboard-iac-worker: dashboard-backend 의 IaC 워커(Dockerfile --target iac-worker, IaC 보안 ADR-13). API 배포 뒤 같은 커밋으로 만든다.
data "aws_ecr_repository" "compliance_worker" {
  name = "${var.project}/dashboard-compliance-worker"
}

resource "aws_ecr_repository" "this" {
  for_each = toset(["dashboard-api", "dashboard-frontend", "dashboard-secret-worker", "dashboard-iac-worker"])

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

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

# ─────────────────────────────────────────────
# ECR 리포지토리
#
# 서비스 단위로 나눈다.
# 리포지토리 개수는 과금되지 않으며 저장 용량과 전송량으로만 계산된다.
#
# 나누면 이미지 스캔 결과를 리포지토리 단위로 확인할 수 있고
# 수명주기 정책과 IAM 권한을 서비스별로 다르게 줄 수 있다.
# ─────────────────────────────────────────────

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.namespace}/${each.value}"
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  # 기본 KMS 키로 저장 시 암호화.
  # AES256 이 기본값이며 추가 비용이 없다.
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.namespace}/${each.value}"
  }
}

# ─────────────────────────────────────────────
# 수명주기 정책
#
# 규칙은 rulePriority 순서로 평가되며
# 먼저 매칭된 규칙이 적용된다.
#
# 태그 없는 이미지를 먼저 정리하고, 그 다음 개수를 제한한다.
# 순서를 바꾸면 태그 없는 이미지가 개수에 포함되어
# 유효한 이미지가 먼저 삭제될 수 있다.
# ─────────────────────────────────────────────

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "태그 없는 이미지 ${var.untagged_expire_days}일 후 삭제"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "최근 ${var.keep_image_count}개만 유지"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
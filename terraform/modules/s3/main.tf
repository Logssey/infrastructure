# ─────────────────────────────────────────────
# S3 버킷
#
# 용도가 다른 버킷 셋을 함께 관리한다.
# 이미지 업로드는 브라우저가 직접 PUT 하므로 CORS 가 필요하고,
# Loki 는 서버 간 통신이라 필요 없다.
#
# 공통 설정(퍼블릭 차단, 암호화)은 for_each 로 묶고
# 버킷별 차이는 개별 리소스로 둔다.
# ─────────────────────────────────────────────

locals {
  buckets = {
    images      = "${var.name_prefix}-s3-images"
    loki_chunks = "${var.name_prefix}-loki-chunks"
    loki_ruler  = "${var.name_prefix}-loki-ruler"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value

  tags = {
    Name = each.value
  }
}

# ─────────────────────────────────────────────
# 퍼블릭 접근 차단
#
# 네 항목을 모두 켠다.
# 이미지는 Presigned URL 로, Loki 는 IAM 으로만 접근한다.
# 어느 쪽도 퍼블릭 읽기가 필요하지 않다.
# ─────────────────────────────────────────────

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─────────────────────────────────────────────
# 암호화
#
# SSE-S3(AES256)를 쓴다. KMS 는 요청마다 과금되고
# 키 관리 부담이 생기는데, 그만한 요구가 없다.
#
# Bucket Key 는 KMS 를 쓸 때 요청 수를 줄이는 기능이다.
# SSE-S3 에서는 영향이 없으나 기존 버킷 설정과 맞춘다.
# ─────────────────────────────────────────────

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ─────────────────────────────────────────────
# 버저닝을 설정하지 않는다
#
# 세 버킷 모두 버저닝이 필요하지 않다.
# 이미지는 사용자가 다시 올릴 수 있고 로그는 보존 기간이 지나면 버린다.
# 켜면 삭제해도 이전 버전이 남아 비용이 늘고
# 수명주기 규칙에 비현재 버전 처리를 따로 넣어야 한다.
#
# aws_s3_bucket_versioning 리소스를 만들지 않는다.
# Terraform 은 Disabled 상태를 표현할 수 없어 Suspended 만 지정할 수 있는데,
# 그것은 "켰다가 끈" 상태이고 한 번도 켜지 않은 것과 API 응답이 다르다.
# 관리하지 않으면 기본값(비활성)이 유지된다.
# ─────────────────────────────────────────────

# ─────────────────────────────────────────────
# 이미지 버킷 — CORS
#
# 백엔드가 Presigned URL 을 발급하고 브라우저가 S3 로 직접 PUT 한다.
# 다른 origin 으로의 요청이므로 CORS 없이는 브라우저가 차단한다.
#
# GET 은 넣지 않는다. 조회도 Presigned URL 을 쓰는데
# 그것은 단순 요청이라 preflight 가 발생하지 않는다.
# ─────────────────────────────────────────────

resource "aws_s3_bucket_cors_configuration" "images" {
  bucket = aws_s3_bucket.this["images"].id

  cors_rule {
    allowed_headers = ["Content-Type"]
    allowed_methods = ["PUT"]
    allowed_origins = var.image_allowed_origins
    max_age_seconds = 3000
  }
}

# ─────────────────────────────────────────────
# 이미지 버킷 — 수명주기
#
# 업로드 흐름은 pending/ → 검증 → verified/ 복사다.
# 검증되지 않거나 상품에 연결되지 않은 객체가 pending/ 에 남는다.
#
# 애플리케이션도 고아 정리를 수행하지만(app.image.orphan-retention)
# 그것이 실패하거나 중단된 경우를 대비해 버킷 차원에서도 만료시킨다.
# ─────────────────────────────────────────────

resource "aws_s3_bucket_lifecycle_configuration" "images" {
  bucket = aws_s3_bucket.this["images"].id

  rule {
    id     = "expire-pending-uploads"
    status = "Enabled"

    filter {
      prefix = "pending/"
    }

    expiration {
      days = 1
    }
  }

  # 완료되지 않은 멀티파트 업로드를 정리한다.
  # 최대 10MB 라 멀티파트를 쓰지 않을 것으로 보이나,
  # 남으면 보이지 않는 저장 비용이 된다.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ─────────────────────────────────────────────
# Loki 청크 버킷 — 수명주기
#
# 보존은 두 곳에서 설정한다.
#
#   Loki retention_period   Loki compactor 가 논리적으로 만료 처리
#   S3 수명주기              실제 객체 삭제
#
# compactor 가 누락한 객체가 남을 수 있어 S3 쪽을 안전망으로 둔다.
# Loki 보존(30일)보다 길게 잡아 compactor 가 먼저 처리하게 한다.
# S3 가 더 짧으면 Loki 가 아직 유효하다고 보는 청크를 지워
# 쿼리 시 오류가 난다.
# ─────────────────────────────────────────────

resource "aws_s3_bucket_lifecycle_configuration" "loki_chunks" {
  bucket = aws_s3_bucket.this["loki_chunks"].id

  rule {
    id     = "expire-old-chunks"
    status = "Enabled"

    filter {}

    expiration {
      days = var.loki_chunk_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

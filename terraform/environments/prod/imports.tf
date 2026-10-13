# ─────────────────────────────────────────────
# 기존 리소스 가져오기
#
# 콘솔에서 만든 리소스를 Terraform 관리 대상으로 옮긴다.
#
# import 블록은 CLI 의 terraform import 보다 낫다.
# plan 에서 결과를 미리 볼 수 있고, 코드와 실제 설정이 다르면
# 변경 항목이 함께 표시된다. 그것을 보고 코드를 맞춘 뒤 apply 한다.
#
# 적용이 끝나면 이 파일을 지운다.
# 남겨두면 plan 마다 실제 리소스를 조회해 느려진다.
# ─────────────────────────────────────────────

# 이미지 업로드 버킷.
# 백엔드 개발 중 콘솔에서 먼저 만들어졌다.
import {
  to = module.s3.aws_s3_bucket.this["images"]
  id = "logssey-prod-s3-images"
}

import {
  to = module.s3.aws_s3_bucket_public_access_block.this["images"]
  id = "logssey-prod-s3-images"
}

import {
  to = module.s3.aws_s3_bucket_server_side_encryption_configuration.this["images"]
  id = "logssey-prod-s3-images"
}

import {
  to = module.s3.aws_s3_bucket_cors_configuration.images
  id = "logssey-prod-s3-images"
}

import {
  to = module.s3.aws_s3_bucket_lifecycle_configuration.images
  id = "logssey-prod-s3-images"
}

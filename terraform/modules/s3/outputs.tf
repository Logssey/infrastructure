output "image_bucket_name" {
  description = "이미지 업로드 버킷 이름. 백엔드 IMAGE_S3_BUCKET 에 넣는다"
  value       = aws_s3_bucket.this["images"].id
}

output "image_bucket_arn" {
  description = "이미지 버킷 ARN. IAM 정책에서 참조한다"
  value       = aws_s3_bucket.this["images"].arn
}

output "loki_chunks_bucket_name" {
  description = "Loki 청크 버킷 이름. Loki values 의 bucketNames.chunks 에 넣는다"
  value       = aws_s3_bucket.this["loki_chunks"].id
}

output "loki_ruler_bucket_name" {
  description = "Loki ruler 버킷 이름"
  value       = aws_s3_bucket.this["loki_ruler"].id
}

output "loki_bucket_arns" {
  description = "Loki 버킷 ARN 목록. IAM 정책에서 참조한다"
  value = [
    aws_s3_bucket.this["loki_chunks"].arn,
    aws_s3_bucket.this["loki_ruler"].arn,
  ]
}

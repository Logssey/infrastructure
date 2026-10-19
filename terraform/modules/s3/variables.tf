variable "name_prefix" {
  description = <<-EOT
    버킷 이름 앞에 붙는 접두사.

    S3 버킷 이름은 AWS 전체에서 고유해야 한다.
    조직·환경을 접두사로 두어 충돌을 피한다.
  EOT
  type        = string
}

variable "image_allowed_origins" {
  description = <<-EOT
    이미지 버킷 CORS 에서 허용할 origin.

    브라우저가 Presigned URL 로 직접 PUT 하므로
    실제 서비스 도메인을 정확히 넣어야 한다.
    와일드카드를 쓰면 다른 사이트에서도 업로드를 시도할 수 있다.

    스킴과 포트까지 일치해야 한다. https://example.com 과
    https://example.com:443 은 다른 값으로 취급된다.
  EOT
  type        = list(string)
}

variable "loki_chunk_retention_days" {
  description = <<-EOT
    Loki 청크 버킷의 객체 만료 일수.

    Loki 의 retention_period 보다 길게 잡는다.
    compactor 가 먼저 정리하고 S3 는 누락분만 처리하는 구조다.

    더 짧게 잡으면 Loki 가 아직 유효하다고 보는 청크를 S3 가 지워
    쿼리 시 오류가 난다.
  EOT
  type        = number
  default     = 35
}

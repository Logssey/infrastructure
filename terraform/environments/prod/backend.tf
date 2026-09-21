terraform {
  # use_lockfile이 1.10부터 지원되므로 최소 버전을 명시한다.
  required_version = ">= 1.10"

  backend "s3" {
    bucket = "logssey-prod-s3-tfstate"

    # 환경별 상태 격리. dev 추가 시 "dev/terraform.tfstate"로 지정한다.
    # 버킷을 나눌 필요는 없다.
    key = "prod/terraform.tfstate"

    region  = "ap-northeast-1"
    encrypt = true

    # S3 조건부 쓰기 기반 잠금. terraform.tfstate.tflock 객체를 생성한다.
    # 기존 방식인 dynamodb_table은 deprecated이며 향후 제거 예정이다.
    # https://developer.hashicorp.com/terraform/language/backend/s3
    use_lockfile = true
  }
}

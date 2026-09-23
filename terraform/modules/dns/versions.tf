terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"

      # CloudFront 용 ACM 인증서와 WAF Web ACL 은 us-east-1 에 생성한다.
      # 루트 모듈에서 providers 블록으로 전달받는다.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
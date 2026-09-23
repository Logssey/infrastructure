terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"

      # CLOUDFRONT scope 의 WAF Web ACL 은 us-east-1 에 생성해야 한다.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"

      # ~> 6.65 = >= 6.65.0, < 7.0.0
      # 6.0에서 breaking change가 있었으므로 메이저 업그레이드를 차단한다.
      # 최신 버전 확인: https://registry.terraform.io/providers/hashicorp/aws/latest
      # (2026-09-21 기준 최신 6.65.0)
      version = "~> 6.65"
    }
  }
}

provider "aws" {
  region = var.region

  # 모든 리소스에 자동 부착. 리소스별 태그는 여기와 겹치지 않는 키만 사용한다.
  # 같은 키를 리소스에서 다시 지정하면 Terraform이 매번 변경으로 감지한다.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

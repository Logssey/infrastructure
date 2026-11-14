terraform {
  required_version = ">= 1.10"

  # prod 와 같은 버킷, 다른 키. Re:Used prod 상태와 나눈다 (ADR-D010).
  # 같은 버킷: Terraform 밖에서 만든 공용 상태 버킷. 버전 관리·암호화·공개 차단이 있고 Re:Used 노드 역할은 Deny로 막혀 있다.
  # 다른 키: 상태와 잠금(.tflock)이 키마다 따로라 prod 와 대시보드의 plan·apply·destroy 가 섞이지 않는다 (ADR-D010).

  backend "s3" {
    bucket       = "logssey-prod-s3-tfstate"
    key          = "logssey-dashboard/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true

  }
}
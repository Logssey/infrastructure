variable "azure_tenant_id" {
  description = <<-EOT
    커넥터를 만든 우리 Azure 테넌트 ID.
    신뢰 정책의 세션 이름(MicrosoftDefenderForClouds_<테넌트 ID>)을 이 테넌트로 제한한다.
  EOT
  type        = string
}

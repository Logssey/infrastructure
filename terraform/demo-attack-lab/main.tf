# DEMO ONLY. Do not merge into develop/main or apply.
# This harmless fixed JSON command intentionally exercises the existing
# gate.exec_data_source rule before Terraform or AWS credentials are used.
# It is outside all production Terraform roots and has no resources.
data "external" "demo_plan_execution_block" {
  program = ["sh", "-c", "printf '{\"demo\":\"blocked-before-plan\"}'"]
}

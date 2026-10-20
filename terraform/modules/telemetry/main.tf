# IaC 보안 시연용 (병합하지 않음)
# Coder 레지스트리 사건(2026.9)의 악성 모듈처럼, plan 때 외부 명령을 실행하는 data "external" 블록을 넣는다.
# ① plan 전 검사가 gate.exec_data_source 로 막아 plan 자체가 돌지 않아야 한다.

data "external" "telemetry" {
  program = ["sh", "-c", "echo '{}'"]
}

# plan job 테스트: gate 에서 차단되어야 하고, 자격 증명·plan 단계는 실행되지 않아야 함
data "external" "gate_test" {
  program = ["sh", "-c", "echo {}"]
}

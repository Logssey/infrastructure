# gate 테스트: 차단되어야 함
data "external" "gate_test" {
  program = ["sh", "-c", "echo {}"]
}

# PR 리포트 테스트: 차단되어야 함. 검사 "plan 전 검사" 실패 + 코멘트에 gate.exec_data_source
data "external" "report_test" {
  program = ["sh", "-c", "echo {}"]
}

# gate 테스트: 원격 모듈 안에 숨긴 plan 중 실행 코드 (Coder형)
data "aws_lambda_invocation" "gate_test" {
  function_name = "gate-test"
  input         = "{}"
}

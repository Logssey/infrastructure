# gate 테스트: 원격 모듈 (2b 에서 차단되어야 함)
module "gate_test" {
  source = "git::https://github.com/Logssey/infrastructure.git//gate-test/helper?ref=test/gate-coder"
}

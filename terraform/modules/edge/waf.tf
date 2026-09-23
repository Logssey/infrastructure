# ─────────────────────────────────────────────
# WAF Web ACL
#
# CLOUDFRONT scope 의 Web ACL 은 us-east-1 에 생성해야 한다.
# 리전이 고정되어 있으며 다른 리전에서는 만들 수 없다.
#
# 모든 룰을 Count 모드로 둔다.
# Block 으로 바로 켜면 정상 요청이 오탐으로 차단될 수 있다.
# 파일 업로드, 긴 쿼리스트링, 특수문자 입력 등이 대표적이다.
#
# 실제 트래픽 패턴을 확인한 뒤 룰별로 Block 으로 전환한다.
#
# 비용: Web ACL 월 $5 + 관리형 룰 그룹당 $1
# ─────────────────────────────────────────────

locals {
  waf_count = var.waf_enabled ? 1 : 0

  # 관리형 룰 그룹. 우선순위 순서대로 평가된다.
  managed_rule_groups = [
    {
      name     = "AWSManagedRulesCommonRuleSet"
      priority = 1
    },
    {
      name     = "AWSManagedRulesKnownBadInputsRuleSet"
      priority = 2
    },
    {
      name     = "AWSManagedRulesAmazonIpReputationList"
      priority = 3
    },
  ]
}

resource "aws_wafv2_web_acl" "main" {
  provider = aws.us_east_1
  count    = local.waf_count

  name  = "${var.name_prefix}-waf"
  scope = "CLOUDFRONT"

  # 룰에 매칭되지 않은 요청은 통과시킨다.
  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups

    content {
      name     = rule.value.name
      priority = rule.value.priority

      # Count 모드.
      # 룰 그룹 안의 개별 룰 동작을 무시하고 전부 카운트만 한다.
      override_action {
        count {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.name_prefix}-waf"
  }
}
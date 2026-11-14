# 데이터 볼륨을 매일 03:00 KST(18:00 UTC)에 스냅샷. crash-consistent 라 Postgres 는 복구 때 WAL 로 맞춘다.
resource "aws_dlm_lifecycle_policy" "data" {
  description        = "Daily snapshot of the Logssey dashboard database volume"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Snapshot = "${local.name_prefix}-data"
    }

    schedule {
      name      = "daily"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["18:00"]
      }

      retain_rule {
        count = var.snapshot_retain_count
      }
    }
  }
}
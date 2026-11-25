# Explicitly approved demo input. This grants content read only to the collector,
# not the API, and does not expose the object publicly or permit bucket listing.
# Remove the resource when the demo target is retired from Logssey.
resource "aws_iam_role_policy" "secret_demo_object" {
  name = "${local.name_prefix}-secret-demo-object"
  role = aws_iam_role.source["worker"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadApprovedSecretDemoObject"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["arn:${data.aws_partition.source_credentials.partition}:s3:::logssey-secret-demo-20261125-jh/logssey-ddemo/logssey-secret-demo.env"]
    }]
  })
}

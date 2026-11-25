# Explicitly approved demo folder. Listing and content reads remain limited to
# this prefix and the collector role; objects are not made public.
# Remove the resource when the demo target is retired from Logssey.
resource "aws_iam_role_policy" "secret_demo_object" {
  name = "${local.name_prefix}-secret-demo-object"
  role = aws_iam_role.source["worker"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadApprovedSecretDemoPrefix"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["arn:${data.aws_partition.source_credentials.partition}:s3:::logssey-secret-demo-20261125-jh/logssey-ddemo/*"]
      }, {
      Sid      = "ListApprovedSecretDemoPrefix"
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = ["arn:${data.aws_partition.source_credentials.partition}:s3:::logssey-secret-demo-20261125-jh"]
      Condition = {
        StringEquals = { "s3:prefix" = "logssey-ddemo/" }
      }
    }]
  })
}

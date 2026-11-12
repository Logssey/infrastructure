# ─────────────────────────────────────────────
# Microsoft Defender for Cloud — CSPM 커넥터 (시험용, 30일)
#
# Azure 포털의 AWS 커넥터가 생성한 AwsOnboarding.tf 에서 CSPM Role 만 옮겼다.
# Azure 가 Microsoft 테넌트의 토큰으로 이 Role 을 assume 해 계정 설정을 읽는다.
#
# 포털 템플릿에서 뺀 것과 이유
#   - provider "aws" 블록 : 모듈 안에 provider 가 있으면 모듈 블록을 지울 때
#                            destroy 할 provider 가 없어 삭제가 실패한다.
#   - module "iam" (원격) : 쓰이지 않는다. gate 관문 2b 대상만 늘린다.
#   - CSPM 확장 Role 6개  : 에이전트 없는 스캔(VmScanner)은 우리 계정에 EBS 스냅샷과
#                            KMS 키를 직접 만든다. Terraform 밖에서 생긴 리소스라
#                            모듈을 지워도 함께 지워지지 않는다. ECR 쓰기(이미지 평가),
#                            kms:Decrypt *(민감 데이터 탐색) 등 쓰기·복호화 권한도 있다.
#                            포털에서도 확장을 모두 끈 상태로 커넥터를 둔다.
#
# 남는 권한은 읽기 전용이고, AWS 쪽에 생기는 리소스는 이 파일의 IAM 뿐이다.
#
# Azure 쪽 (포털에서 생성, Terraform 밖)
#   커넥터      : reused-aws (Korea Central)
#   리소스 그룹 : rg-defender-aws (eastus. 첫 시도 때 생성된 것을 그대로 씀)
#   플랜        : 기본 CSPM 만. Defender CSPM 은 끔 (확장 Role 이 없어 켜면 커넥터 생성 실패)
#   구독(Azure for Students)에 지역 제한 정책이 있어 koreacentral·japaneast·eastasia·
#   indiasouthcentral·malaysiawest 에만 리소스를 만들 수 있다.
#
# 삭제 순서 (시험 종료 시)
#   1. Azure 포털에서 커넥터 삭제 (필요하면 rg-defender-aws 도 삭제)
#   2. prod/main.tf 의 module "defender" 블록 삭제 → plan 이 destroy 만인지 확인 → apply
#   3. 이 디렉터리 삭제
# AWS Role 만 지우면 커넥터가 오류 상태로 남으므로 반드시 1 을 먼저 한다.
# 과금은 Azure 쪽 플랜 설정이 정한다. 기본 CSPM 은 무료다.
# ─────────────────────────────────────────────

locals {
  # Defender for Cloud 멀티클라우드 앱이 있는 Microsoft 테넌트 (모든 고객 공통)
  mdc_tenant_id = "33e01921-4d64-4f8c-a055-5bdaffd5e33d"
  mdc_issuer    = "sts.windows.net/${local.mdc_tenant_id}/"

  # CSPM 앱의 audience
  cspm_audience = "api://4d8bed1f-eee7-4d8e-b0dc-8462049a4479"

  # 커넥터가 이 이름으로 Role 을 찾는다. 이름 규칙({project}-{env}-...)을 따르지 않는다.
  cspm_role_name = "CspmMonitorAws"
}

# thumbprint 는 포털 템플릿 값을 그대로 쓴다.
resource "aws_iam_openid_connect_provider" "mdc" {
  url             = "https://${local.mdc_issuer}"
  client_id_list  = [local.cspm_audience]
  thumbprint_list = ["626d44e704d1ceabe3bf0d53397464ac8080142c"]
}

data "aws_iam_policy_document" "cspm_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.mdc.arn]
    }

    condition {
      test     = "StringLike"
      variable = "${local.mdc_issuer}:aud"
      values   = [local.cspm_audience]
    }

    condition {
      test     = "StringLike"
      variable = "sts:RoleSessionName"
      values   = ["MicrosoftDefenderForClouds_${var.azure_tenant_id}"]
    }
  }
}

resource "aws_iam_role" "cspm_monitor" {
  name               = local.cspm_role_name
  description        = "Microsoft Defender for Cloud - CSPM read only role"
  assume_role_policy = data.aws_iam_policy_document.cspm_assume.json
}

# managed_policy_arns 는 provider 6.x 에서 deprecated 라 attachment 로 붙인다.
resource "aws_iam_role_policy_attachment" "cspm_monitor" {
  for_each = {
    "1" = aws_iam_policy.cspm_monitor_1.arn
    "2" = aws_iam_policy.cspm_monitor_2.arn
  }

  role       = aws_iam_role.cspm_monitor.name
  policy_arn = each.value
}

# ─────────────────────────────────────────────
# CSPM 읽기 정책 (포털 템플릿 원문)
#
# 정책 하나의 크기 제한(6,144자) 때문에 둘로 나뉘어 있다.
# ─────────────────────────────────────────────

resource "aws_iam_policy" "cspm_monitor_1" {
  name        = "${local.cspm_role_name}1"
  description = "Microsoft Defender for Cloud - CSPM monitor policy (part 1)"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:GetRolePolicy",
          "iam:GetUserPolicy",
          "acm:DescribeCertificate",
          "acm:ListCertificates",
          "acm:ListTagsForCertificate",
          "apigateway:GET",
          "application-autoscaling:DescribeScalableTargets",
          "autoscaling:DescribeAutoScalingGroups",
          "bedrock:GetModelInvocationLoggingConfiguration",
          "bedrock:ListKnowledgeBases",
          "bedrock:ListDataSources",
          "bedrock:GetDataSource",
          "bedrock:ListCustomModels",
          "bedrock:ListFoundationModels",
          "bedrock:ListAgents",
          "bedrock:GetAgent",
          "cloudformation:ListStacks",
          "cloudformation:DescribeStacks",
          "cloudformation:DescribeStackSet",
          "cloudformation:ListStackSets",
          "cloudformation:DescribeStackInstance",
          "cloudformation:GetTemplate",
          "cloudformation:ListStackInstances",
          "cloudformation:ListStackResources",
          "cloudfront:DescribeFunction",
          "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig",
          "cloudfront:ListTagsForResource",
          "cloudfront:ListDistributions",
          "cloudtrail:DescribeTrails",
          "cloudtrail:GetEventSelectors",
          "cloudtrail:ListTags",
          "cloudtrail:LookupEvents",
          "cloudtrail:GetTrailStatus",
          "cloudtrail:GetTrail",
          "cloudwatch:ListTagsForResource",
          "cloudwatch:DescribeAlarms",
          "codebuild:BatchGetProjects",
          "codebuild:ListSourceCredentials",
          "codebuild:ListProjects",
          "config:DescribeConfigurationRecorders",
          "config:DescribeDeliveryChannels",
          "config:DescribeConfigurationRecorderStatus",
          "dax:DescribeClusters",
          "dax:ListTags",
          "dms:DescribeReplicationInstances",
          "dynamodb:DescribeTable",
          "dynamodb:ListTables",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:ListTagsOfResource",
          "ec2:DescribeAddresses",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshotAttribute",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:GetEbsEncryptionByDefault",
          "ec2:DescribeFlowLogs",
          "ec2:DescribeRegions",
          "ec2:DescribeSnapshots",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeImages",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeVpcs",
          "ec2:DescribeVolumes",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeVpcEndpoints",
          "ec2:DescribeSubnets",
          "ec2:DescribeNetworkAcls",
          "ec2:DescribeRouteTables",
          "ec2:DescribeInstanceStatus",
          "ecr:GetRegistryPolicy",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetRepositoryPolicy",
          "ecs:ListServices",
          "ecs:ListTagsForResource",
          "ecs:DescribeServices",
          "ecs:ListTaskDefinitions",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:ListClusters",
          "ecs:DescribeClusters",
          "eks:DescribeNodegroup",
          "eks:ListNodegroups",
          "eks:DescribeCluster",
          "eks:ListClusters",
          "elasticbeanstalk:DescribeEnvironments",
          "elasticbeanstalk:DescribeConfigurationSettings",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:DescribeFileSystems",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeLoadBalancerPolicies",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeRules",
          "elasticmapreduce:ListClusters",
          "elasticmapreduce:DescribeCluster",
          "es:ListDomainNames",
          "es:DescribeElasticsearchDomain",
          "es:ListTags",
          "es:DescribeElasticsearchDomains",
          "guardduty:ListDetectors",
          "iam:ListPolicies",
          "iam:GenerateCredentialReport",
          "iam:GetCredentialReport",
          "iam:GetUser",
          "iam:ListRoles",
          "iam:GetRole",
          "iam:GetGroup",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:GetAccountPasswordPolicy",
          "iam:GetGroupPolicy",
          "iam:ListServerCertificates",
          "iam:GetAccessKeyLastUsed",
          "iam:ListEntitiesForPolicy",
          "iam:ListUserPolicies",
          "iam:ListMFADevices",
          "iam:ListInstanceProfiles",
          "iam:ListVirtualMFADevices",
          "iam:ListGroupsForUser",
          "iam:ListAttachedUserPolicies",
          "iam:ListAccountAliases",
          "iam:ListUsers",
          "iam:GetAccountSummary",
          "iam:ListAccessKeys",
          "iam:ListGroupPolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:GetInstanceProfile",
          "iam:GenerateServiceLastAccessedDetails",
          "iam:GetServiceLastAccessedDetails",
          "identitystore:ListUsers",
          "identitystore:ListGroups",
          "identitystore:ListGroupMemberships",
          "kms:ListKeys",
          "kms:ListKeyPolicies",
          "kms:GetKeyRotationStatus",
          "kms:ListAliases",
          "kms:GetKeyPolicy",
          "kms:DescribeKey",
          "lambda:ListFunctions",
          "lambda:ListTags",
          "lambda:GetFunction",
          "lambda:GetPolicy",
          "logs:DescribeLogGroups",
          "logs:DescribeMetricFilters",
          "network-firewall:DescribeLoggingConfiguration",
          "network-firewall:DescribeResourcePolicy",
          "network-firewall:DescribeRuleGroupMetadata",
          "network-firewall:ListTagsForResource",
          "network-firewall:DescribeRuleGroup",
          "network-firewall:DescribeFirewallPolicy",
          "network-firewall:ListFirewalls",
          "network-firewall:DescribeFirewall",
          "network-firewall:ListFirewallPolicies",
          "network-firewall:ListRuleGroups",
          "organizations:ListPoliciesForTarget",
          "organizations:ListTargetsForPolicy",
          "organizations:DescribePolicy",
          "organizations:ListPolicies",
          "organizations:ListOrganizationalUnitsForParent",
          "organizations:ListRoots",
          "organizations:ListAccountsForParent",
          "rds:DescribeDBClusterSnapshotAttributes",
          "rds:DescribeEventSubscriptions",
          "rds:DescribeDBSnapshots",
          "rds:DescribeExportTasks",
          "rds:DescribeDBClusterSnapshots",
          "rds:DescribeDBInstances",
          "rds:DescribeDBClusters",
          "rds:DescribeDBSnapshotAttributes",
          "redshift:DescribeClusters",
          "redshift:DescribeLoggingStatus",
          "redshift:DescribeClusterParameterGroups",
          "redshift:DescribeClusterParameters",
          "s3:GetEncryptionConfiguration",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketTagging",
          "s3:GetBucketLogging",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation",
          "s3:GetBucketPolicy",
          "s3:GetReplicationConfiguration",
          "s3:GetAccountPublicAccessBlock",
          "s3:GetObjectAcl",
          "s3:GetObjectTagging",
          "s3:ListBucket",
          "s3:ListAllMyBuckets",
          "s3:GetBucketPolicyStatus",
          "s3:GetLifecycleConfiguration",
          "s3:GetBucketVersioning",
          "sagemaker:DescribeNotebookInstance",
          "sagemaker:ListNotebookInstances",
          "sagemaker:GetSearchSuggestions",
          "sagemaker:Search",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets",
          "sns:ListTagsForResource",
          "sns:ListTopics"
        ],
        "Resource" : "*"
      }
    ]
  })
}

resource "aws_iam_policy" "cspm_monitor_2" {
  name        = "${local.cspm_role_name}2"
  description = "Microsoft Defender for Cloud - CSPM monitor policy (part 2)"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "sns:GetTopicAttributes",
          "sns:ListSubscriptions",
          "sqs:ListQueues",
          "sqs:GetQueueAttributes",
          "sqs:ListQueueTags",
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeParameters",
          "ssm:ListTagsForResource",
          "ssm:ListResourceComplianceSummaries",
          "sso:ListInstances",
          "sso:ListPermissionSets",
          "sso:ListAccountsForProvisionedPermissionSet",
          "sso:DescribePermissionSet",
          "sso:ListAccountAssignments",
          "states:ListStateMachines",
          "sts:GetCallerIdentity",
          "waf-regional:GetWebACLForResource",
          "waf-regional:GetRuleGroup",
          "waf-regional:GetPermissionPolicy",
          "waf-regional:GetWebACL",
          "waf-regional:GetSampledRequests",
          "waf-regional:GetLoggingConfiguration",
          "waf-regional:GetRule",
          "wafv2:ListResourcesForWebACL",
          "wafv2:ListWebACLs",
          "waf:ListWebACLs",
          "waf:GetLoggingConfiguration",
          "waf:GetWebACL",
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "appsync:ListGraphqlApis",
          "access-analyzer:ListAnalyzers",
          "route53domains:ListDomains",
          "macie2:GetMacieSession",
          "macie2:ListClassificationJobs",
          "resource-explorer-2:ListTagsForResource",
          "amplify:ListApps",
          "acm-pca:ListCertificateAuthorities",
          "apprunner:ListServices",
          "memorydb:DescribeClusters",
          "kinesisanalytics:ListApplications",
          "events:ListRules",
          "storagegateway:ListGateways",
          "elasticache:DescribeCacheClusters",
          "batch:DescribeJobQueues",
          "qbusiness:ListApplications",
          "lightsail:GetBuckets",
          "lightsail:GetBucketAccessKeys",
          "lightsail:GetRelationalDatabases",
          "lightsail:GetDisks",
          "lightsail:GetDiskSnapshots",
          "sagemaker:ListEndpoints",
          "sagemaker:DescribeEndpoint"
        ],
        "Resource" : "*"
      }
    ]
  })
}

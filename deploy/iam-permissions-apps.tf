# Permissions for application stacks (3am-core, 3am-internal, 3am-ocsp).
# Cross-stack SSM contract reads use parameter/3am* (see -Extra).
#
# Inline policies on a role share a combined 10,240-character quota — prefer
# service wildcards and broad ARN patterns over long action/resource lists.

resource "aws_iam_role_policy" "three_am_deployment_apps" {
  name   = "ThreeAM-Deployment-Permissions-Apps"
  role   = aws_iam_role.three_am_deployment.id
  policy = data.aws_iam_policy_document.deployment_permissions_apps.json
}

data "aws_iam_policy_document" "deployment_permissions_apps" {
  # terraform-aws-modules/lambda looks up AWS-managed policy documents at plan time.
  # policy/* does not match policy/service-role/* (IAM * does not span /).
  statement {
    sid    = "IamReadAwsManagedPolicies"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
    ]
    resources = [
      "arn:${local.partition}:iam::aws:policy/*",
      "arn:${local.partition}:iam::aws:policy/service-role/*",
      "arn:${local.partition}:iam::aws:policy/aws-service-role/*",
      "arn:${local.partition}:iam::aws:policy/job-function/*",
    ]
  }

  statement {
    sid       = "LambdaOnAppFunctions"
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["arn:${local.partition}:lambda:*:${local.account_id}:function:*"]
  }

  statement {
    sid       = "IamManageAppStackRolesAndPolicies"
    effect    = "Allow"
    actions   = ["iam:*"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/*",
      "arn:${local.partition}:iam::${local.account_id}:policy/*",
    ]
  }

  statement {
    sid    = "IamAccountPasswordPolicy"
    effect = "Allow"
    actions = [
      "iam:GetAccountPasswordPolicy",
      "iam:UpdateAccountPasswordPolicy",
      "iam:DeleteAccountPasswordPolicy",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "RdsManageCoreStack"
    effect    = "Allow"
    actions   = ["rds:*"]
    resources = ["arn:${local.partition}:rds:*:${local.account_id}:*"]
  }

  # CreateSecret is evaluated before the secret ARN exists.
  statement {
    sid       = "SecretsManagerCore"
    effect    = "Allow"
    actions   = ["secretsmanager:*"]
    resources = ["*"]
  }

  statement {
    sid       = "SesCore"
    effect    = "Allow"
    actions   = ["ses:*"]
    resources = ["*"]
  }

  statement {
    sid       = "SqsCore"
    effect    = "Allow"
    actions   = ["sqs:*"]
    resources = ["arn:${local.partition}:sqs:*:${local.account_id}:*"]
  }

  statement {
    sid    = "S3AccountPublicAccessBlock"
    effect = "Allow"
    actions = [
      "s3:GetAccountPublicAccessBlock",
      "s3:PutAccountPublicAccessBlock",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "S3CreateAndManageAppBuckets"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      "arn:${local.partition}:s3:::3am-*",
      "arn:${local.partition}:s3:::3am-*/*",
      "arn:${local.partition}:s3:::alb-*-3am-*",
      "arn:${local.partition}:s3:::alb-*-3am-*/*",
      "arn:${local.partition}:s3:::trail-*",
      "arn:${local.partition}:s3:::trail-*/*",
      "arn:${local.partition}:s3:::*.3amops.com",
      "arn:${local.partition}:s3:::*.3amops.com/*",
    ]
  }

  statement {
    sid    = "KmsCreateCoreSigningKeys"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:EnableKeyRotation",
      "kms:DisableKeyRotation",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "KmsXpkiKeys"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["arn:${local.partition}:kms:*:${local.account_id}:alias/xpki/*"]
  }

  statement {
    sid       = "EventsListRules"
    effect    = "Allow"
    actions   = ["events:ListRules"]
    resources = ["*"]
  }

  statement {
    sid       = "EventsCoreRules"
    effect    = "Allow"
    actions   = ["events:*"]
    resources = ["arn:${local.partition}:events:*:${local.account_id}:rule/*"]
  }

  statement {
    sid       = "ElbManageAppLoadBalancers"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:*"]
    resources = ["*"]
  }
}

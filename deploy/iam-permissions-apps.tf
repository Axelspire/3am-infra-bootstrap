# Permissions for application stacks (3am-core, 3am-internal, 3am-ocsp).
# Cross-stack SSM contract reads use parameter/3am* (see -Extra).

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

  # App Lambdas use pki-*, authorizer-*, etc. (not the 3am-* prefix on -Permissions).
  statement {
    sid       = "LambdaOnAppFunctions"
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["arn:${local.partition}:lambda:*:${local.account_id}:function:*"]
  }

  # Lambda execution roles/policies created by app stacks (names are not 3am-*).
  statement {
    sid       = "IamManageAppStackRolesAndPolicies"
    effect    = "Allow"
    actions   = ["iam:*"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/*",
      "arn:${local.partition}:iam::${local.account_id}:policy/*",
    ]
  }

  # Internal ALB access-log bucket and core trail/SIEM buckets (see 3am-internal,
  # 3am-core modules). Audit bucket permissions live on -Permissions-Onboarding.
  statement {
    sid    = "S3CreateAndManageAppBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucketAcl",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketObjectLockConfiguration",
      "s3:PutBucketTagging",
      "s3:Get*",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:${local.partition}:s3:::alb-*-3am-access-logs",
      "arn:${local.partition}:s3:::alb-*-3am-access-logs/*",
      "arn:${local.partition}:s3:::trail-pki-*",
      "arn:${local.partition}:s3:::trail-pki-*/*",
      "arn:${local.partition}:s3:::*.3amops.com",
      "arn:${local.partition}:s3:::*.3amops.com/*",
    ]
  }

  # Internal ALB + OCSP/datasink target groups/listeners (ELB ARNs are not
  # prefixable at create time; scoped to this app-stack policy only).
  statement {
    sid       = "ElbManageAppLoadBalancers"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:*"]
    resources = ["*"]
  }
}

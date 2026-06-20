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

  statement {
    sid       = "LambdaOnAppFunctions"
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["arn:${local.partition}:lambda:*:${local.account_id}:function:*"]
  }

  # Lambda execution roles/policies and account password policy (3am-core iam module).
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
    sid    = "RdsManageCoreStack"
    effect = "Allow"
    actions = ["rds:*"]
    resources = [
      "arn:${local.partition}:rds:*:${local.account_id}:db:*",
      "arn:${local.partition}:rds:*:${local.account_id}:cluster:*",
      "arn:${local.partition}:rds:*:${local.account_id}:subgrp:*",
      "arn:${local.partition}:rds:*:${local.account_id}:pg:*",
      "arn:${local.partition}:rds:*:${local.account_id}:optgrp:*",
    ]
  }

  # CreateSecret is evaluated before the secret ARN exists; secret:* alone is insufficient.
  statement {
    sid    = "SecretsManagerCreateCoreSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "SecretsManagerManageCoreSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:*"]
    resources = ["arn:${local.partition}:secretsmanager:*:${local.account_id}:secret:*"]
  }

  statement {
    sid       = "SesCoreEmail"
    effect    = "Allow"
    actions   = ["ses:*"]
    resources = ["*"]
  }

  statement {
    sid       = "SqsCoreQueues"
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

  # Core per-customer buckets, internal ALB logs, SIEM hostnames, legacy trail names.
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
      "arn:${local.partition}:s3:::3am-rootca-*",
      "arn:${local.partition}:s3:::3am-rootca-*/*",
      "arn:${local.partition}:s3:::3am-crl-*",
      "arn:${local.partition}:s3:::3am-crl-*/*",
      "arn:${local.partition}:s3:::3am-trail-*",
      "arn:${local.partition}:s3:::3am-trail-*/*",
      "arn:${local.partition}:s3:::alb-*-3am-access-logs",
      "arn:${local.partition}:s3:::alb-*-3am-access-logs/*",
      "arn:${local.partition}:s3:::trail-pki-*",
      "arn:${local.partition}:s3:::trail-pki-*/*",
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
    sid       = "KmsXpkiAliases"
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
    sid       = "EventsCoreSchedulerRules"
    effect    = "Allow"
    actions   = ["events:*"]
    resources = [
      "arn:${local.partition}:events:*:${local.account_id}:rule/3am-*",
      "arn:${local.partition}:events:*:${local.account_id}:rule/acme-*",
      "arn:${local.partition}:events:*:${local.account_id}:rule/cloudtrail-*",
    ]
  }

  statement {
    sid       = "ElbManageAppLoadBalancers"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:*"]
    resources = ["*"]
  }
}

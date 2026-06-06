# Cross-account IAM deployment role.
#
# Trusted only by AxelSpire's CI role in AxelSpire's CI account, with
# defence-in-depth conditions stacked on top:
#   - sts:RoleSessionName must start with "3am-" (attribution).
#   - sts:ExternalId must match the customer-controlled value (optional).
#   - aws:RequestTag/LicenseValid must be true (optional).
#
# The permission policy is intentionally narrow: ARN patterns matching
# 3am-* resources only, plus tag-conditioned access for the few resource
# types that don't accept ARN patterns. See docs/REVIEWING.md.

resource "aws_iam_role" "three_am_deployment" {
  name                 = "ThreeAM-Deployment"
  description          = "Cross-account role assumed by AxelSpire CI to deploy 3AM resources for ${var.customer_id}."
  assume_role_policy   = data.aws_iam_policy_document.deployment_trust.json
  max_session_duration = 3600
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "three_am_deployment" {
  name   = "ThreeAM-Deployment-Permissions"
  role   = aws_iam_role.three_am_deployment.id
  policy = data.aws_iam_policy_document.deployment_permissions.json
}

# ------------------------------------------------------------------ #
# Trust policy
# ------------------------------------------------------------------ #

data "aws_iam_policy_document" "deployment_trust" {
  statement {
    sid     = "AllowAxelspireCIAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${var.axelspire_ci_account_id}:role/${var.axelspire_ci_role_name}"]
    }

    condition {
      test     = "StringLike"
      variable = "sts:RoleSessionName"
      values   = ["3am-*", "tg-*"]
    }

    dynamic "condition" {
      for_each = local.use_external_id ? [1] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [local.external_id_value]
      }
    }

    dynamic "condition" {
      for_each = var.require_license_session_tag ? [1] : []
      content {
        test     = "StringEquals"
        variable = "aws:RequestTag/LicenseValid"
        values   = ["true"]
      }
    }
  }
}

# ------------------------------------------------------------------ #
# Permission policy: trust-anchor resources
# ------------------------------------------------------------------ #
# Scope: the state bucket, the lock table, the CMK data-plane, and the
# Lambda function ARN pattern. EC2, SSM, Logs, APIGW, R53, ACM live in
# iam-permissions-ec2.tf and iam-permissions-extra.tf.

data "aws_iam_policy_document" "deployment_permissions" {
  # Lambda functions named 3am-*
  statement {
    sid       = "LambdaOn3amFunctions"
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["arn:${local.partition}:lambda:*:${local.account_id}:function:3am-*"]
  }

  # KMS data-plane on the customer CMK only.
  statement {
    sid    = "KmsDataPlaneOnCustomerCmk"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.three_am.arn]
  }

  # S3 on the state bucket only. The audit bucket is created and
  # extended by 3am-customer-onboarding (the layer that runs after this
  # one); its permissions are added there.
  statement {
    sid    = "S3OnStateBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  # DynamoDB lock table only.
  statement {
    sid    = "DynamoDBOnStateLockTable"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.state_lock.arn]
  }
}

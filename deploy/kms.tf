# Customer-managed KMS key (CMK).
#
# The key is owned by the customer's account and used by every downstream
# 3AM stack to encrypt data at rest (S3 objects, DynamoDB tables, SSM
# SecureString parameters, CloudWatch logs, Lambda environment variables).
#
# AxelSpire is granted only data-plane operations on this key
# (Encrypt / Decrypt / GenerateDataKey / DescribeKey). Key administration
# (rotate, disable, schedule deletion, modify policy) stays with the
# customer's admin roles and the account root.

resource "aws_kms_key" "three_am" {
  description             = "3AM customer-managed CMK for ${var.customer_id}"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = var.kms_key_rotation_enabled
  multi_region            = var.kms_multi_region
  policy                  = data.aws_iam_policy_document.cmk.json
  tags                    = local.common_tags
}

resource "aws_kms_alias" "three_am" {
  name          = "alias/3am-customer-cmk"
  target_key_id = aws_kms_key.three_am.key_id
}

# ------------------------------------------------------------------ #
# Key policy
# ------------------------------------------------------------------ #
# Four logical statements:
#   1. Account root: full kms:* (the standard "self" statement; without
#      this the customer can lock themselves out of their own key).
#   2. Customer admin roles: full key management.
#   3. AxelSpire deployment role: data-plane operations only.
#   4. Lambda service principal in this account, scoped via the
#      kms:ViaService condition, so the key can be used as the CMK for
#      Lambda environment variables and dead-letter queues.

data "aws_iam_policy_document" "cmk" {
  statement {
    sid     = "EnableIAMUserPermissions"
    effect  = "Allow"
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.customer_admin_role_arns) > 0 ? [1] : []
    content {
      sid    = "AllowCustomerAdminsKeyManagement"
      effect = "Allow"
      actions = [
        "kms:Create*",
        "kms:Describe*",
        "kms:Enable*",
        "kms:List*",
        "kms:Put*",
        "kms:Update*",
        "kms:Revoke*",
        "kms:Disable*",
        "kms:Get*",
        "kms:Delete*",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:ScheduleKeyDeletion",
        "kms:CancelKeyDeletion",
      ]
      principals {
        type        = "AWS"
        identifiers = var.customer_admin_role_arns
      }
      resources = ["*"]
    }
  }

  statement {
    sid    = "AllowAxelspireDeploymentRoleDataPlane"
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
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.three_am_deployment.arn]
    }
    resources = ["*"]
  }

  statement {
    sid    = "AllowLambdaServiceUseInThisAccount"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["lambda.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
  }
}

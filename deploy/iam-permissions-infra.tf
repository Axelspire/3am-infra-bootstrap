# Permissions for the 3am-infra stack (VPC, shared APIGW domain, firewall
# Lambda, /3am-infra/* SSM contract). Attached as a scoped inline policy
# so bootstrap can be upgraded without widening the trust-anchor policy.

resource "aws_iam_role_policy" "three_am_deployment_infra" {
  name   = "ThreeAM-Deployment-Permissions-Infra"
  role   = aws_iam_role.three_am_deployment.id
  policy = data.aws_iam_policy_document.deployment_permissions_infra.json
}

data "aws_iam_policy_document" "deployment_permissions_infra" {
  statement {
    sid       = "SsmOn3amInfraParameters"
    effect    = "Allow"
    actions   = ["ssm:*"]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter/3am-infra/*"]
  }

  statement {
    sid    = "Ec2NetworkingCreateWith3amTag"
    effect = "Allow"
    actions = [
      "ec2:Create*",
      "ec2:AllocateAddress",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid       = "Ec2NetworkingManageTagged"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid    = "Ec2FlowLogs"
    effect = "Allow"
    actions = [
      "ec2:CreateFlowLogs",
      "ec2:DeleteFlowLogs",
    ]
    resources = ["*"]
  }

  # NACL/subnet association replaces the VPC default NACL (untagged); cannot
  # require aws:ResourceTag/Service=3am on the authorization resource.
  statement {
    sid    = "Ec2NaclAssociations"
    effect = "Allow"
    actions = [
      "ec2:ReplaceNetworkAclAssociation",
      "ec2:AssociateNetworkAclSubnet",
      "ec2:DisassociateNetworkAclSubnet",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "IamManage3amScopedPoliciesAndRoles"
    effect    = "Allow"
    actions   = ["iam:*"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:policy/3am-*",
      "arn:${local.partition}:iam::${local.account_id}:role/3am-*",
    ]
  }

  statement {
    sid       = "EventsListRules"
    effect    = "Allow"
    actions   = ["events:ListRules"]
    resources = ["*"]
  }

  statement {
    sid       = "EventsOn3amRules"
    effect    = "Allow"
    actions   = ["events:*"]
    resources = ["arn:${local.partition}:events:*:${local.account_id}:rule/3am-*"]
  }

  statement {
    sid    = "KmsCreate3amTaggedKeys"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:TagResource",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid    = "KmsCreate3amAliases"
    effect = "Allow"
    actions = ["kms:CreateAlias"]
    resources = [
      "arn:${local.partition}:kms:*:${local.account_id}:alias/3am-*",
      "arn:${local.partition}:kms:*:${local.account_id}:key/*",
    ]
  }

  statement {
    sid    = "KmsManage3amAliases"
    effect = "Allow"
    actions = [
      "kms:UpdateAlias",
      "kms:DeleteAlias",
    ]
    resources = [
      "arn:${local.partition}:kms:*:${local.account_id}:alias/3am-*",
      "arn:${local.partition}:kms:*:${local.account_id}:key/*",
    ]
  }

  statement {
    sid       = "KmsManage3amTaggedKeys"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = ["3am"]
    }
  }
}

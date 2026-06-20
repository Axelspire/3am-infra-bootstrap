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

  # Infra VPC apply uses inline routes, IGW attach, NACL association, and
  # flow logs where tag-based authorization does not match (default NACL,
  # route-table routes, etc.). Scoped to this inline policy only.
  statement {
    sid       = "Ec2InfraVpc"
    effect    = "Allow"
    actions   = ["ec2:*"]
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

  # ListAliases is account-scoped (Resource "*"). Key/alias data-plane and
  # management for the infra CMK use alias/3am-* and key/* patterns.
  statement {
    sid       = "KmsListAccountScope"
    effect    = "Allow"
    actions   = ["kms:ListAliases", "kms:ListKeys"]
    resources = ["*"]
  }

  statement {
    sid       = "KmsOn3amKeysAndAliases"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = [
      "arn:${local.partition}:kms:*:${local.account_id}:alias/3am-*",
      "arn:${local.partition}:kms:*:${local.account_id}:key/*",
    ]
  }
}

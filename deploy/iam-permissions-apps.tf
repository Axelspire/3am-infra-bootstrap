# Permissions for application stacks (3am-core, 3am-internal, 3am-ocsp).
# Cross-stack SSM contract reads use parameter/3am* (see -Extra).

resource "aws_iam_role_policy" "three_am_deployment_apps" {
  name   = "ThreeAM-Deployment-Permissions-Apps"
  role   = aws_iam_role.three_am_deployment.id
  policy = data.aws_iam_policy_document.deployment_permissions_apps.json
}

data "aws_iam_policy_document" "deployment_permissions_apps" {
  # terraform-aws-modules/lambda looks up AWS-managed policy documents at plan time.
  statement {
    sid    = "IamReadAwsManagedPolicies"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
    ]
    resources = ["arn:${local.partition}:iam::aws:policy/*"]
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
}

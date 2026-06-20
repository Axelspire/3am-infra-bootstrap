# Additional permissions for the ThreeAM-Deployment role.
#
# Split out from iam.tf to keep each file readable. AWS attaches each
# aws_iam_role_policy independently to the role; the effective
# permissions are the union of all attached policies.
#
# Scoping rules (see docs/REVIEWING.md):
#   - Resource ARN patterns matching 3am-* wherever supported.
#   - aws:ResourceTag / aws:RequestTag conditions for resource types
#     that don't accept ARN patterns.
#   - Service-level action wildcards (ssm:*, logs:*, …) only where
#     resource ARNs or tag conditions keep the blast radius narrow.

resource "aws_iam_role_policy" "three_am_deployment_extra" {
  name   = "ThreeAM-Deployment-Permissions-Extra"
  role   = aws_iam_role.three_am_deployment.id
  policy = data.aws_iam_policy_document.deployment_permissions_extra.json
}

data "aws_iam_policy_document" "deployment_permissions_extra" {
  statement {
    sid       = "SsmOn3amParameters"
    effect    = "Allow"
    actions   = ["ssm:*"]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter/3am/*"]
  }

  statement {
    sid       = "SsmDescribeParameters"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # DescribeLogGroups / CreateLogGroup require Resource "*" (see AWS CWL IAM docs).
  statement {
    sid       = "LogsAccountScope"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups", "logs:CreateLogGroup"]
    resources = ["*"]
  }

  statement {
    sid       = "LogsOn3amGroups"
    effect    = "Allow"
    actions   = ["logs:*"]
    resources = [
      "arn:${local.partition}:logs:*:${local.account_id}:log-group:/aws/lambda/3am-*",
      "arn:${local.partition}:logs:*:${local.account_id}:log-group:/aws/vpc/3am-*",
      "arn:${local.partition}:logs:*:${local.account_id}:log-group:/3am/*",
    ]
  }

  statement {
    sid       = "ApigatewayCreateWith3amTag"
    effect    = "Allow"
    actions   = ["apigateway:*"]
    resources = ["arn:${local.partition}:apigateway:*::/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid       = "ApigatewayOnTaggedResources"
    effect    = "Allow"
    actions   = ["apigateway:*"]
    resources = ["arn:${local.partition}:apigateway:*::/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid       = "Route53Read"
    effect    = "Allow"
    actions   = ["route53:Get*", "route53:List*"]
    resources = ["*"]
  }

  statement {
    sid    = "Route53WriteOnTaggedZones"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ChangeTagsForResource",
    ]
    resources = ["arn:${local.partition}:route53:::hostedzone/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/3am-managed"
      values   = ["true"]
    }
  }

  statement {
    sid       = "AcmOnTaggedCertificates"
    effect    = "Allow"
    actions   = ["acm:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid       = "AcmListAndRequest"
    effect    = "Allow"
    actions   = ["acm:ListCertificates", "acm:RequestCertificate"]
    resources = ["*"]
  }
}

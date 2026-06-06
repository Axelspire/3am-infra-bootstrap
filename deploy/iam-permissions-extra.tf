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
#   - No iam:*, no organizations:*, no broad s3:* or ec2:* anywhere.

resource "aws_iam_role_policy" "three_am_deployment_extra" {
  name   = "ThreeAM-Deployment-Permissions-Extra"
  role   = aws_iam_role.three_am_deployment.id
  policy = data.aws_iam_policy_document.deployment_permissions_extra.json
}

data "aws_iam_policy_document" "deployment_permissions_extra" {
  # SSM read on /3am/* parameters.
  statement {
    sid    = "SsmReadOn3amParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:DescribeParameters",
    ]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter/3am/*"]
  }

  # SSM write on /3am/* parameters (downstream stacks publish their
  # outputs here).
  statement {
    sid    = "SsmWriteOn3amParameters"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:DeleteParameters",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:LabelParameterVersion",
    ]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter/3am/*"]
  }

  # CloudWatch Logs on 3am-* log groups (Lambda log groups follow the
  # /aws/lambda/3am-* pattern; the module's own /3am/* hierarchy is
  # also covered).
  statement {
    sid    = "LogsOn3amGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:AssociateKmsKey",
    ]
    resources = [
      "arn:${local.partition}:logs:*:${local.account_id}:log-group:/aws/lambda/3am-*",
      "arn:${local.partition}:logs:*:${local.account_id}:log-group:/aws/lambda/3am-*:*",
      "arn:${local.partition}:logs:*:${local.account_id}:log-group:/3am/*",
      "arn:${local.partition}:logs:*:${local.account_id}:log-group:/3am/*:*",
    ]
  }

  # API Gateway: deploy / manage APIs tagged Service=3am.
  statement {
    sid    = "ApiGatewayOnTaggedResources"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
      "apigateway:TagResource",
      "apigateway:UntagResource",
    ]
    resources = ["arn:${local.partition}:apigateway:*::/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = ["3am"]
    }
  }

  # Route 53: read on hosted zones; write only on zones tagged
  # 3am-managed=true.
  statement {
    sid    = "Route53Read"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
    ]
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

  # ACM on certificates tagged Service=3am, plus list/request which
  # don't support resource-level tags.
  statement {
    sid    = "AcmOnTaggedCertificates"
    effect = "Allow"
    actions = [
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:ListTagsForCertificate",
      "acm:DeleteCertificate",
      "acm:AddTagsToCertificate",
      "acm:RemoveTagsFromCertificate",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid    = "AcmListAndRequest"
    effect = "Allow"
    actions = [
      "acm:ListCertificates",
      "acm:RequestCertificate",
    ]
    resources = ["*"]
  }
}

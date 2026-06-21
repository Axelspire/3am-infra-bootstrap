# Additional permissions for the ThreeAM-Deployment role.
#
# Split out from iam.tf to keep each file readable. AWS attaches each
# aws_iam_role_policy independently to the role; the effective
# permissions are the union of all attached policies.
#
# Inline policies on a role share a combined 10,240-character quota — keep
# this document compact (service wildcards on * or broad ARN patterns).

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
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter/3am*"]
  }

  statement {
    sid       = "SsmDescribeParameters"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # DescribeLogGroups / CreateLogGroup require Resource "*".
  statement {
    sid       = "LogsCore"
    effect    = "Allow"
    actions   = ["logs:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ApigatewayCore"
    effect    = "Allow"
    actions   = ["apigateway:*"]
    resources = ["arn:${local.partition}:apigateway:*::/*"]
  }

  statement {
    sid       = "Route53Core"
    effect    = "Allow"
    actions   = ["route53:*"]
    resources = ["*"]
  }

  statement {
    sid       = "AcmCore"
    effect    = "Allow"
    actions   = ["acm:*"]
    resources = ["*"]
  }

  # CloudWatch alarms (PutMetricAlarm has no resource-tag condition
  # path; 3am-core also creates a few legacy-named alarms tracked
  # for a separate rename pass).
  statement {
    sid       = "CloudWatchCore"
    effect    = "Allow"
    actions   = ["cloudwatch:*"]
    resources = ["*"]
  }

  # CloudTrail. Trail names today include non-3am-* (pki-${env}-trail);
  # tracked for rename.
  statement {
    sid       = "CloudTrailCore"
    effect    = "Allow"
    actions   = ["cloudtrail:*"]
    resources = ["*"]
  }

  # Lambda event source mappings. CreateEventSourceMapping evaluates
  # against arn:...:event-source-mapping:* (UUID is unknown at create).
  # Scope via lambda:FunctionArn to 3am-* functions.
  statement {
    sid    = "LambdaEventSourceMappingsOn3amFunctions"
    effect = "Allow"
    actions = [
      "lambda:CreateEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:ListEventSourceMappings",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "lambda:FunctionArn"
      values   = ["arn:${local.partition}:lambda:*:${local.account_id}:function:3am-*"]
    }
  }
}

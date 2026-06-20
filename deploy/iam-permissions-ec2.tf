# EC2 permissions split out for readability.
#
# Read on VPC topology resources is broad-but-read-only; write on
# security groups is narrowed to those tagged Service=3am.

resource "aws_iam_role_policy" "three_am_deployment_ec2" {
  name   = "ThreeAM-Deployment-Permissions-Ec2"
  role   = aws_iam_role.three_am_deployment.id
  policy = data.aws_iam_policy_document.deployment_permissions_ec2.json
}

data "aws_iam_policy_document" "deployment_permissions_ec2" {
  statement {
    sid    = "Ec2VpcRead"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:GetManagedPrefixListEntries",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Ec2SecurityGroupWriteOnTagged"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["arn:${local.partition}:ec2:*:${local.account_id}:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid       = "Ec2SecurityGroupCreate"
    effect    = "Allow"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Service"
      values   = ["3am"]
    }
  }
}

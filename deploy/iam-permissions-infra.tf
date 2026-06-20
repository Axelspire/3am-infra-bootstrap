# Permissions for the 3am-infra stack (VPC, shared APIGW domain, firewall
# Lambda, /3am-infra/* SSM contract). Attached as a fourth scoped inline
# policy so bootstrap can be upgraded without widening the trust-anchor policy.

resource "aws_iam_role_policy" "three_am_deployment_infra" {
  name   = "ThreeAM-Deployment-Permissions-Infra"
  role   = aws_iam_role.three_am_deployment.id
  policy = data.aws_iam_policy_document.deployment_permissions_infra.json
}

data "aws_iam_policy_document" "deployment_permissions_infra" {
  statement {
    sid    = "SsmReadOn3amInfraParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter/3am-infra/*"]
  }

  statement {
    sid    = "SsmWriteOn3amInfraParameters"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:DeleteParameters",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsForResource",
      "ssm:ListTagsForResource",
      "ssm:LabelParameterVersion",
    ]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter/3am-infra/*"]
  }

  # Read-only EC2 APIs used by the 3am-infra network module during plan/apply
  # (EIP/NAT wait loops call DescribeAddresses, etc.). Also present on
  # ThreeAM-Deployment-Permissions-Ec2; duplicated here so infra deploy is
  # not blocked when the Ec2 inline policy is stale or missing.
  statement {
    sid    = "Ec2NetworkingRead"
    effect = "Allow"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeSubnets",
      "ec2:DescribeRouteTables",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNatGateways",
      "ec2:DescribeAddresses",
      "ec2:DescribeVpcEndpoints",
      "ec2:DescribeManagedPrefixLists",
      "ec2:GetManagedPrefixListEntries",
      "ec2:DescribeNetworkAcls",
      "ec2:DescribeFlowLogs",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeRegions",
      "ec2:DescribeAccountAttributes",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Ec2NetworkingCreateWith3amTag"
    effect = "Allow"
    actions = [
      "ec2:CreateVpc",
      "ec2:CreateSubnet",
      "ec2:CreateInternetGateway",
      "ec2:CreateRouteTable",
      "ec2:CreateRoute",
      "ec2:AllocateAddress",
      "ec2:CreateNatGateway",
      "ec2:CreateVpcEndpoint",
      "ec2:CreateManagedPrefixList",
      "ec2:CreateNetworkAcl",
      "ec2:CreateNetworkAclEntry",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Service"
      values   = ["3am"]
    }
  }

  statement {
    sid    = "Ec2NetworkingManageTagged"
    effect = "Allow"
    actions = [
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:ReleaseAddress",
      "ec2:DeleteNatGateway",
      "ec2:DeleteVpcEndpoints",
      "ec2:ModifyVpcEndpoint",
      "ec2:ModifyManagedPrefixList",
      "ec2:DeleteManagedPrefixList",
      "ec2:DeleteNetworkAcl",
      "ec2:DeleteNetworkAclEntry",
      "ec2:ReplaceNetworkAclEntry",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:DeleteSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
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

  statement {
    sid    = "IamManage3amScopedPoliciesAndRoles"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListPolicyTags",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PassRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
    ]
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
    sid    = "EventsOn3amRules"
    effect = "Allow"
    actions = [
      "events:PutRule",
      "events:DeleteRule",
      "events:DescribeRule",
      "events:EnableRule",
      "events:DisableRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:ListTargetsByRule",
      "events:TagResource",
      "events:UntagResource",
      "events:ListTagsForResource",
    ]
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
    sid    = "KmsManage3amTaggedKeys"
    effect = "Allow"
    actions = [
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
      "kms:ListAliases",
      "kms:PutKeyPolicy",
      "kms:GetKeyPolicy",
      "kms:EnableKeyRotation",
      "kms:DisableKey",
      "kms:EnableKey",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:UntagResource",
      "kms:ListResourceTags",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Service"
      values   = ["3am"]
    }
  }
}

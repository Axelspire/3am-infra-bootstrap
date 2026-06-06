# Runtime configuration parameters under /3am/.
#
# Every downstream 3AM stack reads from these parameters rather than
# accepting them as Terraform inputs, so an upgrade of this module
# automatically propagates without changing every consumer.
#
# Parameters created here describe ONLY the bootstrap-layer resources
# (CMK, state bucket, lock table, deployment role). The
# 3am-customer-onboarding module that runs after this one adds further
# parameters for the audit bucket and license/governance metadata.

resource "aws_ssm_parameter" "kms_key_arn" {
  name        = "/3am/kms/customer-cmk-arn"
  description = "ARN of the customer-managed CMK."
  type        = "String"
  value       = aws_kms_key.three_am.arn
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "kms_key_id" {
  name        = "/3am/kms/customer-cmk-id"
  description = "Key ID of the customer-managed CMK."
  type        = "String"
  value       = aws_kms_key.three_am.key_id
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "state_bucket" {
  name        = "/3am/state/bucket-name"
  description = "Name of the S3 bucket holding Terraform state."
  type        = "String"
  value       = aws_s3_bucket.state.id
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "state_lock_table" {
  name        = "/3am/state/lock-table-name"
  description = "Name of the DynamoDB state-lock table."
  type        = "String"
  value       = aws_dynamodb_table.state_lock.name
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "deployment_role_arn" {
  name        = "/3am/iam/deployment-role-arn"
  description = "ARN of the ThreeAM-Deployment role."
  type        = "String"
  value       = aws_iam_role.three_am_deployment.arn
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "bootstrap_version" {
  name        = "/3am/bootstrap/version"
  description = "Version of the bootstrap module that was last applied."
  type        = "String"
  value       = local.module_version
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "bootstrap_applied_at" {
  name        = "/3am/bootstrap/applied-at"
  description = "Timestamp of the last apply of the bootstrap module."
  type        = "String"
  value       = timestamp()
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "external_id" {
  count       = local.use_external_id ? 1 : 0
  name        = "/3am/license/external-id"
  description = "External ID for AssumeRole into ThreeAM-Deployment (mirror of the customer-managed Secrets Manager secret)."
  type        = "SecureString"
  key_id      = aws_kms_key.three_am.arn
  value       = local.external_id_value
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

output "customer_kms_key_arn" {
  description = "ARN of the customer-managed CMK. Consumed by downstream stacks for encryption."
  value       = aws_kms_key.three_am.arn
}

output "customer_kms_key_id" {
  description = "Key ID of the customer CMK."
  value       = aws_kms_key.three_am.key_id
}

output "customer_kms_key_alias" {
  description = "Alias of the customer CMK."
  value       = aws_kms_alias.three_am.name
}

output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "state_lock_table_name" {
  description = "Name of the DynamoDB table for state locking."
  value       = aws_dynamodb_table.state_lock.name
}

output "deployment_role_arn" {
  description = "ARN of the ThreeAM-Deployment role for cross-account assumption."
  value       = aws_iam_role.three_am_deployment.arn
}

output "deployment_role_name" {
  description = "Name of the deployment role."
  value       = aws_iam_role.three_am_deployment.name
}

output "ssm_parameter_paths" {
  description = "Map of SSM parameter paths created for runtime lookup."
  value = {
    bootstrap_version                = aws_ssm_parameter.bootstrap_version.name
    bootstrap_applied                = aws_ssm_parameter.bootstrap_applied_at.name
    kms_key_arn                      = aws_ssm_parameter.kms_key_arn.name
    kms_key_id                       = aws_ssm_parameter.kms_key_id.name
    state_bucket                     = aws_ssm_parameter.state_bucket.name
    state_lock_table                 = aws_ssm_parameter.state_lock_table.name
    deployment_role_arn              = aws_ssm_parameter.deployment_role_arn.name
    axelspire_artifact_kms_key_arn   = aws_ssm_parameter.axelspire_artifact_kms_key_arn.name
    axelspire_artifact_s3_bucket_arn = aws_ssm_parameter.axelspire_artifact_s3_bucket_arn.name
  }
}

output "bootstrap_version" {
  description = "Version of this module that was applied."
  value       = local.module_version
}

output "handoff_values" {
  description = "Convenience bundle of values to share with AxelSpire after apply (deployment_role_arn, customer_kms_key_arn, state_bucket_name, state_lock_table_name, customer_id, region). Includes the AxelSpire-supplied CI inputs (echoed back) so the hand-off is self-describing."
  value = {
    customer_id                      = var.customer_id
    region                           = local.region
    account_id                       = local.account_id
    deployment_role_arn              = aws_iam_role.three_am_deployment.arn
    customer_kms_key_arn             = aws_kms_key.three_am.arn
    state_bucket_name                = aws_s3_bucket.state.id
    state_lock_table_name            = aws_dynamodb_table.state_lock.name
    axelspire_artifact_kms_key_arn   = var.axelspire_artifact_kms_key_arn
    axelspire_artifact_s3_bucket_arn = var.axelspire_artifact_s3_bucket_arn
    bootstrap_version                = local.module_version
  }
}

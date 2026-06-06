# Module entrypoint: locals, data sources, common tags.
#
# Resources live in the resource-specific files: kms.tf, iam.tf,
# iam-permissions-ec2.tf, iam-permissions-extra.tf, state-backend.tf,
# ssm.tf.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  # Bumped on every release. Read by deployment workflows to detect
  # whether the customer's bootstrap stack needs an upgrade before a
  # downstream stack can be applied.
  module_version = "0.1.0"

  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  partition  = data.aws_partition.current.partition

  # Resource name prefix. Every resource this module creates either
  # carries this prefix in its name or is tagged Service=3am, so the
  # deployment role's permission policy can scope itself tightly.
  name_prefix = "3am"

  common_tags = merge(
    {
      Service          = "3am"
      CustomerId       = var.customer_id
      ManagedBy        = "3am-infra-bootstrap"
      BootstrapVersion = local.module_version
    },
    var.tags,
  )

  # Optionally fetch the external ID value from the customer-managed
  # Secrets Manager secret. The trust policy uses the value, not the
  # secret ARN.
  use_external_id   = var.external_id_secret_arn != null
  external_id_value = local.use_external_id ? data.aws_secretsmanager_secret_version.external_id[0].secret_string : null
}

data "aws_secretsmanager_secret_version" "external_id" {
  count     = local.use_external_id ? 1 : 0
  secret_id = var.external_id_secret_arn
}

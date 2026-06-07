# Pattern 1: customer-applied bootstrap.
#
# The customer's platform team runs this in their own AWS account using
# their own admin credentials. AxelSpire is never present in the apply
# path; it only becomes a trusted Principal AFTER the apply succeeds.
#
# Typical execution:
#
#   export AWS_PROFILE=customer-admin
#   tofu init
#   tofu apply -var-file=acme.tfvars
#
# Where acme.tfvars contains the four required inputs (see below).

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "customer_id" {
  type = string
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "axelspire_ci_account_id" {
  type = string
}

variable "customer_admin_role_arns" {
  type = list(string)
}

# Supplied by AxelSpire after the customer-onboard PR is merged and
# platform-deploy provisions the per-customer CI CMK + shared artifacts
# bucket. The alias form is recommended for the KMS ARN.
variable "axelspire_artifact_kms_key_arn" {
  type = string
}

variable "axelspire_artifact_s3_bucket_arn" {
  type = string
}

# Customer-controlled secret holding the external ID. Rotated by the
# customer; AxelSpire is given the current value out-of-band. Pre-create
# this secret manually or via a separate module so its lifecycle is
# decoupled from the bootstrap.
data "aws_secretsmanager_secret" "external_id" {
  name = "/3am/license/external-id"
}

module "three_am_bootstrap" {
  source = "../../deploy"

  customer_id                      = var.customer_id
  axelspire_ci_account_id          = var.axelspire_ci_account_id
  customer_admin_role_arns         = var.customer_admin_role_arns
  external_id_secret_arn           = data.aws_secretsmanager_secret.external_id.arn
  axelspire_artifact_kms_key_arn   = var.axelspire_artifact_kms_key_arn
  axelspire_artifact_s3_bucket_arn = var.axelspire_artifact_s3_bucket_arn

  tags = {
    Environment = "production"
    Owner       = "platform-team"
  }
}

output "handoff_values" {
  description = "Share these with AxelSpire over the agreed secure channel."
  value       = module.three_am_bootstrap.handoff_values
}

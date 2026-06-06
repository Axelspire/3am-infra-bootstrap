# Pattern 2: AxelSpire-provisioned bootstrap.
#
# AxelSpire creates a new AWS account inside its own Organization, runs
# the bootstrap module into it via the OrganizationAccountAccessRole AWS
# injects on account creation, and then invites the account into the
# customer's Organization. The customer accepts the invite and takes
# ownership.
#
# After this point, the customer can revoke AxelSpire's access at any
# time by editing the trust policy on ThreeAM-Deployment - exactly the
# same revocation path as Pattern 1.
#
# This example is run by AxelSpire, not by the customer.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.60"
      configuration_aliases = [aws.management, aws.new_account]
    }
  }
}

variable "customer_id" {
  type = string
}

variable "customer_account_email" {
  description = "Email address that owns the new AWS account. Must be unique across AWS."
  type        = string
}

variable "customer_account_name" {
  type = string
}

variable "axelspire_ci_account_id" {
  type = string
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "external_id" {
  description = "External ID to seed into the customer-managed secret. Rotated after hand-off."
  type        = string
  sensitive   = true
}

# 1. Create the empty AWS account inside AxelSpire's Organization.
#    OrganizationAccountAccessRole is created automatically by AWS.
resource "aws_organizations_account" "customer" {
  provider = aws.management

  name      = var.customer_account_name
  email     = var.customer_account_email
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    ignore_changes = [role_name]
  }
}

# 2. Provider alias that assumes into the new account.
#    Declared as a configuration_alias at the top so the consumer (the
#    AxelSpire onboarding repo) wires it in their root module.

# 3. Customer-managed secret holding the external ID. Created inside the
#    new account using the alias.
resource "aws_secretsmanager_secret" "external_id" {
  provider = aws.new_account

  name        = "/3am/license/external-id"
  description = "External ID for AssumeRole into ThreeAM-Deployment. Rotate after hand-off."
}

resource "aws_secretsmanager_secret_version" "external_id" {
  provider = aws.new_account

  secret_id     = aws_secretsmanager_secret.external_id.id
  secret_string = var.external_id
}

# 4. Apply the bootstrap module inside the new account.
module "three_am_bootstrap" {
  source = "../../deploy"

  providers = {
    aws = aws.new_account
  }

  customer_id              = var.customer_id
  axelspire_ci_account_id  = var.axelspire_ci_account_id
  external_id_secret_arn   = aws_secretsmanager_secret.external_id.arn
  customer_admin_role_arns = []

  tags = {
    Environment    = "production"
    Provisioned    = "axelspire"
    AccountVending = "organizations"
  }
}

output "new_account_id" {
  value = aws_organizations_account.customer.id
}

output "handoff_values" {
  value = module.three_am_bootstrap.handoff_values
}

output "next_steps" {
  description = "Manual steps AxelSpire performs after this apply."
  value       = <<-EOT
    1. From AxelSpire's Org-management account, send an Organization
       invitation to the customer.
    2. The customer accepts the invitation from their Org-management
       account. The account moves into the customer's Organization.
    3. The customer's platform team rotates the external ID stored in
       /3am/license/external-id; AxelSpire receives the new value
       out-of-band.
    4. The customer can now revoke AxelSpire's access at any time by
       editing the trust policy on ThreeAM-Deployment.
  EOT
}

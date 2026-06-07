variable "customer_id" {
  description = "Unique customer identifier (lowercase, alphanumeric, hyphens). Used in resource tags."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.customer_id))
    error_message = "customer_id must be lowercase alphanumeric with hyphens."
  }
}

variable "axelspire_ci_account_id" {
  description = "AWS account ID of AxelSpire's CI account. The deployment role trusts this account only."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.axelspire_ci_account_id))
    error_message = "Must be a 12-digit AWS account ID."
  }
}

variable "axelspire_ci_role_name" {
  description = "Name of the IAM role in AxelSpire's CI account that will assume into this account."
  type        = string
  default     = "GitHubActions-CustomerDeploy"
}

variable "axelspire_artifact_kms_key_arn" {
  description = "ARN (or alias ARN) of the AxelSpire-owned KMS CMK in the CI account that encrypts this customer's Terraform state and Lambda code artifacts. AxelSpire retains administrative control of this key so license expiry can render the customer's state and code unreadable without touching customer-owned resources. The alias form (arn:aws:kms:<region>:<ci_account>:alias/3am-ci/<customer_id>) is accepted and recommended."
  type        = string
  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key/[a-f0-9-]+|alias/[A-Za-z0-9/_-]+)$", var.axelspire_artifact_kms_key_arn))
    error_message = "Must be a KMS key or alias ARN (arn:aws:kms:<region>:<account>:key/... or .../alias/...)."
  }
}

variable "axelspire_artifact_s3_bucket_arn" {
  description = "ARN of the AxelSpire CI account S3 bucket that hosts encrypted Lambda code zips for this customer. The ThreeAM-Deployment role is granted cross-account s3:GetObject on this bucket so downstream stacks can fetch and deploy Lambda packages."
  type        = string
  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:s3:::[a-z0-9.-]+$", var.axelspire_artifact_s3_bucket_arn))
    error_message = "Must be an S3 bucket ARN (arn:aws:s3:::<bucket-name>)."
  }
}

variable "external_id_secret_arn" {
  description = "Optional ARN of a customer-managed Secrets Manager secret containing the external ID. The customer rotates this; AxelSpire is given the current value out-of-band. If null, no external ID condition is applied."
  type        = string
  default     = null
}

variable "customer_admin_role_arns" {
  description = "Customer IAM role ARNs that hold administrative access to the CMK. Should include break-glass and platform-team roles."
  type        = list(string)
  default     = []
}

variable "require_license_session_tag" {
  description = "If true, the deployment role can only be assumed when the LicenseValid session tag is true."
  type        = bool
  default     = true
}

variable "state_bucket_force_vpce" {
  description = "If set, the state bucket policy requires access via this VPC endpoint."
  type        = string
  default     = null
}

variable "kms_key_rotation_enabled" {
  description = "Enable annual automatic KMS key rotation."
  type        = bool
  default     = true
}

variable "kms_multi_region" {
  description = "Create the CMK as a multi-region key. Required if the customer plans to deploy across multiple regions and wants shared encryption."
  type        = bool
  default     = false
}

variable "kms_deletion_window_days" {
  description = "Deletion window for the CMK if scheduled for deletion."
  type        = number
  default     = 30
  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "tags" {
  description = "Additional tags applied to all resources. Service=3am and CustomerId are added automatically."
  type        = map(string)
  default     = {}
}

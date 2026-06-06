# OpenTofu and provider version pins.
#
# Kept narrow on purpose: this module is the trust anchor between the
# customer and AxelSpire. A security reviewer should know the exact
# provider surface they are auditing.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

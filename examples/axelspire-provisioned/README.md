# Example: AxelSpire-provisioned bootstrap

AxelSpire creates a new AWS account inside its own Organization, runs
the bootstrap module into it, then invites the account into the
customer's Organization. The end state is identical to the
customer-applied pattern: the customer owns every resource and can
revoke AxelSpire's access without involving AxelSpire.

## Prerequisites

1. AxelSpire's Organization-management account credentials, with
   permission to create accounts (`organizations:CreateAccount`) and
   to assume `OrganizationAccountAccessRole` in the newly-created
   account.
2. A reserved customer account email address.
3. A pre-generated external ID (32 bytes of hex is fine):
   `openssl rand -hex 32`.

## Providers

The root caller of this example must supply two AWS providers as
aliases:

| Alias | Credentials | Purpose |
|---|---|---|
| `aws.management` | AxelSpire Org-management role | Creates the account. |
| `aws.new_account` | `OrganizationAccountAccessRole` in the new account | Runs the bootstrap. |

A typical wiring (in the calling root module) looks like:

```hcl
provider "aws" {
  alias  = "management"
  region = var.region
  # AxelSpire org-management credentials in environment.
}

provider "aws" {
  alias  = "new_account"
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${aws_organizations_account.customer.id}:role/OrganizationAccountAccessRole"
    session_name = "3am-bootstrap"
  }
}
```

Because the `new_account` provider depends on the account ID that
doesn't exist until the first apply, this example is normally run in
two phases:

```
tofu apply -target=aws_organizations_account.customer
tofu apply
```

## Hand-off

1. AxelSpire sends an Organization invitation from the management
   account.
2. The customer accepts from their own management account.
3. The customer rotates the external ID; AxelSpire receives the new
   value out-of-band.
4. AxelSpire's only foothold is now the cross-account trust on
   `ThreeAM-Deployment`. The customer can revoke it at will.

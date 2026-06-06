# 3am-infra-bootstrap

A single, versioned [OpenTofu](https://opentofu.org) module that creates the
**trust anchor** between a customer's AWS account and AxelSpire's deployment
pipeline. It is applied exactly once per customer account, before any other
3AM stack can run.

It produces five things, all owned entirely by the customer's account:

- A customer-managed KMS key (CMK) with alias `alias/3am-customer-cmk`.
- A cross-account IAM role `ThreeAM-Deployment` that AxelSpire's CI assumes
  to deploy and operate the 3AM product. It carries no long-lived credentials
  and can be revoked unilaterally by the customer at any time.
- An S3 bucket (`3am-state-<account>-<region>`) and DynamoDB table
  (`3am-state-lock`) used as the Terraform state backend for every later
  3AM stack.
- `/3am/*` SSM parameters that downstream stacks read to discover the above.

This module is intentionally minimal and reviewable. A security reviewer
should be able to read this README, [`docs/REVIEWING.md`](docs/REVIEWING.md),
[`deploy/iam.tf`](deploy/iam.tf) and [`deploy/kms.tf`](deploy/kms.tf) in
about 30 minutes and produce an informed approval decision.

## Who runs it

Two patterns are supported. Both result in the same end state — the
customer owns every resource and can revoke AxelSpire's access without
involving AxelSpire.

| Pattern | Who runs the module | When it is appropriate |
|---|---|---|
| **Customer-applied** | The customer's platform team, with their own admin credentials, into an account in the customer's AWS Organization. | Default. The customer's security policy requires that no third party perform the initial setup. See [`examples/customer-applied/`](examples/customer-applied/). |
| **AxelSpire-provisioned** | AxelSpire, into a newly-created AWS account inside the AxelSpire AWS Organization. After bootstrap, the account is invited into the customer's Organization and ownership is transferred. | Optional "managed onboarding" — customer does not have to drive the account-vending process. See [`examples/axelspire-provisioned/`](examples/axelspire-provisioned/). |

In both patterns the apply runs **inside the target customer account**. The
AxelSpire CI account is a `Principal` in the role's trust policy, not a
runner of this module.

## What it creates

| Resource | Name | Owned by | Purpose |
|---|---|---|---|
| KMS key | `alias/3am-customer-cmk` | Customer | Encryption-at-rest for every downstream 3AM resource. |
| IAM role | `ThreeAM-Deployment` | Customer | Cross-account assume target for AxelSpire CI. No `iam:*`, no `organizations:*`, no broad `s3:*` or `ec2:*`. |
| IAM role policies | `ThreeAM-Deployment-Permissions{,-Ec2,-Extra}` | Customer | Narrow allow-list scoped by ARN prefix `3am-*` and resource tag `Service=3am`. |
| S3 bucket | `3am-state-<account>-<region>` | Customer | Terraform state for every 3AM stack. Versioned, KMS-encrypted, TLS-only. |
| DynamoDB table | `3am-state-lock` | Customer | Terraform state locking. PITR enabled, KMS-encrypted. |
| SSM parameters | `/3am/{kms,state,iam,bootstrap,license}/...` | Customer | Runtime discovery of the above by downstream stacks. |

## How it fits the wider 3AM platform

```
Phase 0  3am-infra-bootstrap          <- this module
            creates: role, CMK, state bucket, lock table

Phase 1  3am-customer-onboarding      (applied by 3am-deployments)
            creates: audit bucket, /3am/audit/*, /3am/onboarding/*,
                     /3am/license/* parameters

Phase 2  3am-infra, 3am-core, 3am-ocsp, 3am-datasink
            (applied by 3am-deployments, gated by license/approval tier)
```

See [`3AM_PROJECTS_OVERVIEW.md`](../3AM_PROJECTS_OVERVIEW.md) for the full
dependency map.

## Usage

### Pattern 1: customer-applied (default)

```hcl
module "axelspire_3am_bootstrap" {
  source = "github.com/Axelspire/3am-infra-bootstrap//deploy?ref=v0.1.0"

  customer_id              = "acme-corp"
  axelspire_ci_account_id  = "111122223333"

  customer_admin_role_arns = [
    "arn:aws:iam::123456789012:role/PlatformAdmin",
    "arn:aws:iam::123456789012:role/BreakGlass",
  ]

  external_id_secret_arn = aws_secretsmanager_secret.axelspire_external_id.arn
}
```

After applying, share the outputs of `module.axelspire_3am_bootstrap.handoff_values`
with AxelSpire via secure channel (see [`docs/REVIEWING.md`](docs/REVIEWING.md)
§ "Hand-off").

### Pattern 2: AxelSpire-provisioned (with account creation)

See [`examples/axelspire-provisioned/main.tf`](examples/axelspire-provisioned/main.tf)
for the full flow: `aws_organizations_account` creates the empty account
inside AxelSpire's Organization, a provider alias assumes the
`OrganizationAccountAccessRole` AWS injects into every new account, and the
bootstrap module is applied through that alias.

After apply, AxelSpire emits an Organization invitation; the customer's
Org-management role accepts it; the account moves into the customer's
Organization. From that point forward the customer can revoke AxelSpire's
access unilaterally.

## Inputs and outputs

See [`deploy/variables.tf`](deploy/variables.tf) and
[`deploy/outputs.tf`](deploy/outputs.tf). The most important ones:

| Input | Required | Default |
|---|:---:|---|
| `customer_id` | ✅ | — |
| `axelspire_ci_account_id` | ✅ | — |
| `axelspire_ci_role_name` |  | `GitHubActions-CustomerDeploy` |
| `external_id_secret_arn` |  | `null` |
| `customer_admin_role_arns` |  | `[]` |
| `require_license_session_tag` |  | `true` |
| `kms_key_rotation_enabled` |  | `true` |
| `kms_multi_region` |  | `false` |

`output.handoff_values` is the convenience bundle to share with AxelSpire
(deployment role ARN, CMK ARN, state bucket, lock table, region).

## Security model

- Every resource is owned by the customer account. Revocation requires no
  AxelSpire involvement: delete the trust statement on `ThreeAM-Deployment`
  or detach its permission policies, and AxelSpire is locked out within
  minutes.
- The `ThreeAM-Deployment` role is scoped by ARN patterns matching `3am-*`
  and resources tagged `Service=3am`. No `iam:*`, no `organizations:*`, no
  broad `s3:*` or `ec2:*`.
- Trust is conditioned on `sts:RoleSessionName` starting with `3am-` /
  `tg-`, an optional customer-controlled `sts:ExternalId`, and an optional
  `aws:RequestTag/LicenseValid=true` session tag.
- The CMK key policy grants AxelSpire only data-plane operations
  (`Encrypt`, `Decrypt`, `GenerateDataKey`, `DescribeKey`). Key management
  (rotate, disable, modify policy) stays with the customer.

For the full walkthrough, see [`docs/REVIEWING.md`](docs/REVIEWING.md).

## Requirements

- OpenTofu `>= 1.6` (Terraform `>= 1.5` also works).
- AWS provider `~> 5.60`.
- Credentials with permission to create KMS, IAM, S3, DynamoDB, and SSM
  resources in the target account. The customer's `PlatformAdmin` role is
  sufficient; the AxelSpire CI role is **not** — this module must run
  before that role exists.

## Versioning

Semantic versioning. Major bumps for breaking changes to inputs/outputs;
minor for additive changes; patch for documentation and bug fixes.

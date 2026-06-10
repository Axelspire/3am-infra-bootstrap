# 3am-infra-bootstrap

Creates the **trust anchor** between a customer's AWS account and
AxelSpire's deployment pipeline. Applied exactly once per customer
account, before any other 3AM stack can run.

The recommended path is the **CloudShell setup script**: one `curl`,
one `apply`, one JSON file to send to AxelSpire. The script produces
the same end state as the [OpenTofu module in `deploy/`](deploy/), which
remains available for customers that prefer to drive bootstrap through
their existing IaC (see [Appendix A](#appendix-a--opentofu-module-optional))
and is the canonical source for the
[security review](docs/REVIEWING.md).

- [Run the setup (CloudShell)](#run-the-setup-cloudshell)
- [The output JSON](#the-output-json)
- [Troubleshooting](#troubleshooting)
- [Hand-off to AxelSpire](#hand-off-to-axelspire)
- [Verify the apply](#verify-the-apply)
- [Reference](#reference) — what it creates, where it fits, security model
- [Appendix A — OpenTofu module (optional)](#appendix-a--opentofu-module-optional)
- [Appendix B — Manual AWS CLI walkthrough (reference only)](#appendix-b--manual-aws-cli-walkthrough-reference-only)

---

## Run the setup (CloudShell)

Two variants of the same script, depending on account topology. Both
run in AWS CloudShell against the customer's Org-management account,
both are idempotent (`list → create-if-missing` for every resource),
both embed their policy bodies as heredocs (single-file `curl` deploy),
and both expose the same `apply` / `preflight` / `outputs` /
`outputs-json` sub-commands.

| Variant | Script | When to use |
|---|---|---|
| **Multi-account** | [`_scripts/customer-org-setup.sh`](_scripts/customer-org-setup.sh) | Default. Creates a dedicated 3AM workload AWS account inside a `3AM` OU under the Org root. Attaches SCPs to the OU. Recommended pattern — keeps the 3AM workload separate from the Org-management account. |
| **Single-account** | [`_scripts/single-account-setup.sh`](_scripts/single-account-setup.sh) | The 3AM workload runs in the same AWS account as the Org root (small customers, POCs, freshly-signed-up AWS account used as-is). Skips account / OU creation; assignments target the current caller account. Attaches SCPs to root (no-op for the management account but inherited by any future child accounts). Opt out with `--skip-scps`. |

Both create the same downstream Identity Center surface:

- `3am-region-deny` and `3am-root-user-deny` SCPs.
- `PlatformAdmin` (8h) and `BreakGlass` (1h) permission sets.
- `3AM-Platform-Admins` and `3AM-BreakGlass` groups, members, and the
  account assignments that bind them to the workload account.

**All identities created by these scripts are customer-owned.** The
`--platform-admin-user`, `--breakglass-user`, the `3AM-Platform-Admins`
and `3AM-BreakGlass` groups, and the `PlatformAdmin` / `BreakGlass`
permission sets all live in the customer's Identity Center directory
and grant access only to the customer's own account. AxelSpire never
appears as a user in the customer's directory; its only foothold is
the separate `ThreeAM-Deployment` IAM role provisioned later by this
module — see [Security model](#security-model) and
[`docs/REVIEWING.md`](docs/REVIEWING.md).

> **AxelSpire-side prerequisite.** The `ThreeAM-Deployment` trust
> policy created in Phase 5 names the AxelSpire CI role
> `arn:aws:iam::033113129683:role/GitHubActions-CustomerDeploy` as
> its principal. IAM validates that this role exists at
> `CreateRole` time and rejects the trust policy with
> `MalformedPolicyDocument: Invalid principal in policy` if it does
> not. **AxelSpire must have provisioned `GitHubActions-CustomerDeploy`
> in account `033113129683` before any customer bootstrap can run.**
> This is a one-time AxelSpire-side setup, not per-customer. Override
> the role name with `--axelspire-ci-role-name` if AxelSpire has
> renamed it; override the account with `--axelspire-ci-account-id`
> for non-production AxelSpire environments. See
> [Troubleshooting → Invalid principal in policy](#troubleshooting).

```sh
# Multi-account (creates a new child account in a 3AM OU)
curl -fsSLO https://raw.githubusercontent.com/Axelspire/3am-infra-bootstrap/main/_scripts/customer-org-setup.sh
chmod +x customer-org-setup.sh
./customer-org-setup.sh apply \
  --customer-name "Acme Corp" \
  --account-email aws-3am@acme.example.com \
  --platform-admin-user alice@acme.example.com \
  --breakglass-user bob@acme.example.com \
  --allowed-regions "eu-west-1,us-east-1"
./customer-org-setup.sh outputs-json > org-setup.json

# Single-account (use the current account as the 3AM workload)
# --customer-name and --platform-admin-user are auto-derived from
# the IAM account alias and Organization.MasterAccountEmail; only
# --breakglass-user is mandatory (must be a deliberate identity).
curl -fsSLO https://raw.githubusercontent.com/Axelspire/3am-infra-bootstrap/main/_scripts/single-account-setup.sh
chmod +x single-account-setup.sh
./single-account-setup.sh apply \
  --breakglass-user bob@acme.example.com \
  --allowed-regions "eu-west-1,us-east-1"
./single-account-setup.sh outputs-json > org-setup.json
```

`--allowed-regions` (CSV, default `eu-west-1,us-east-1`) is the
parameter for the `3am-region-deny` SCP. Anything not in the list is
denied for non-global services; IAM, Organizations, Route 53,
CloudFront, WAF, STS, KMS, S3 account-level reads, Health, Tag and
Global Accelerator are always exempt because they're global or
control-plane services. Include at minimum your primary workload
region and `us-east-1` (CloudFront, ACM-for-CloudFront and several
global services have hidden `us-east-1` API hops).

Re-running either script with a different `--allowed-regions` value
calls `organizations:UpdatePolicy` on the existing SCP, so the policy
body is rewritten in-place and all existing attachments pick up the
new region list immediately. The policy name, ID and attachments do
not change.

Logs are written to `$HOME/3am-{org,single-account}-setup-<utc>.log`.
`outputs-json` re-resolves every value from AWS by name, so it always
reflects the live state and is safe to re-run from a fresh session —
see [The output JSON](#the-output-json) for the schema and
`jq`-friendly spot-checks.

---

## The output JSON

Each `apply` writes a single hand-off file to CloudShell's persistent
home so it survives session restarts:

| Script | Output file |
|---|---|
| `customer-org-setup.sh` (multi-account) | `$HOME/3am-org-setup-outputs.json` |
| `single-account-setup.sh` (single-account) | `$HOME/3am-single-account-setup-outputs.json` |

Both files share the same schema: a top-level identity envelope plus
two nested objects — `phase0` (Identity Center / SCPs) and `phase5`
(bootstrap: deployment role, customer CMK, state backend, SSM):

```json
{
  "bootstrap_version": "0.1.0",
  "customer_name": "Acme Corp",
  "customer_id": "acme-corp",
  "mgmt_account_id": "111111111111",
  "account_id": "222222222222",
  "account_name": "3AM-AcmeCorp",
  "ou_id": "ou-abcd-12345678",
  "region": "eu-west-1",
  "partition": "aws",
  "phase0": {
    "identity_center_instance_arn": "arn:aws:sso:::instance/ssoins-…",
    "identity_store_id": "d-90661a8c5a",
    "region_deny_policy_id": "p-0n0msfyr",
    "root_user_deny_policy_id": "p-sjxlgst5",
    "platform_admin_permission_set_arn": "arn:aws:sso:::permissionSet/…",
    "breakglass_permission_set_arn":     "arn:aws:sso:::permissionSet/…",
    "platform_admins_group_id": "64a8f4a8-…",
    "breakglass_group_id":      "d4e89418-…",
    "platform_admin_role_arn":  "arn:aws:iam::222222222222:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_PlatformAdmin_…",
    "breakglass_role_arn":      "arn:aws:iam::222222222222:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_BreakGlass_…",
    "customer_admin_role_arns": ["…PlatformAdmin…", "…BreakGlass…"]
  },
  "phase5": {
    "deployment_role_name":  "ThreeAM-Deployment",
    "deployment_role_arn":   "arn:aws:iam::222222222222:role/ThreeAM-Deployment",
    "customer_cmk_alias":    "alias/3am-customer-cmk",
    "customer_cmk_key_id":   "abcd1234-…",
    "customer_cmk_arn":      "arn:aws:kms:eu-west-1:222222222222:key/abcd1234-…",
    "external_id_secret_name": "/3am/license/external-id",
    "external_id_secret_arn":  "arn:aws:secretsmanager:eu-west-1:222222222222:secret:/3am/license/external-id-…",
    "state_bucket_name":       "3am-state-222222222222-eu-west-1",
    "state_lock_table_name":   "3am-state-lock",
    "axelspire_ci_account_id": "033113129683",
    "axelspire_ci_region":     "eu-west-1",
    "axelspire_ci_role_name":  "GitHubActions-CustomerDeploy",
    "axelspire_artifact_kms_key_arn":   "arn:aws:kms:eu-west-1:033113129683:alias/3am-ci/acme-corp",
    "axelspire_artifact_s3_bucket_arn": "arn:aws:s3:::3am-ci-artifacts-033113129683-eu-west-1"
  }
}
```

The **external-ID secret value** is deliberately *not* in this file. It
is generated inside the workload account at `apply` time and stays in
Secrets Manager under `/3am/license/external-id`. See
[Hand-off to AxelSpire](#hand-off-to-axelspire) for how to fetch and
share it.

Re-running `outputs-json` regenerates the file by re-resolving every
value from AWS by name, so it always reflects the live state and is
safe to run from a fresh CloudShell session:

```sh
./customer-org-setup.sh outputs-json > "$HOME/3am-org-setup-outputs.json"
```

For the multi-account script, `outputs-json` transparently
`sts:AssumeRole`s into the workload account using
`OrganizationAccountAccessRole` to re-resolve the `phase5.*` values. If
that assume fails (e.g. the role was deleted) the `phase5` block is
emitted with empty strings rather than aborting.

### Spot-checks before sending the JSON

```sh
OUTPUTS=$HOME/3am-org-setup-outputs.json

# Both AWSReservedSSO role ARNs resolved (not pending)?
jq '.phase0.customer_admin_role_arns | length' "$OUTPUTS"
# → 2

# Region-deny SCP body matches what you passed in --allowed-regions?
aws organizations describe-policy \
  --policy-id "$(jq -r .phase0.region_deny_policy_id "$OUTPUTS")" \
  --query 'Policy.Content' --output text | python3 -m json.tool | head -20

# Phase 5 fully applied?
jq '.phase5 | {deployment_role_arn, customer_cmk_arn, state_bucket_name, external_id_secret_arn}' "$OUTPUTS"
```

If any `phase5.*` value is empty, re-run `apply` — every step is
idempotent.

---

## Troubleshooting

**`IAM Identity Center is not enabled in this region. Enable it in the console (one-time, Org-mgmt account) and re-run.`**

AWS Identity Center has no public API for the initial activation; it
must be enabled once per Organization through the AWS console. Both
setup scripts surface this as a preflight failure rather than try to
proceed without it.

To resolve:

1. Sign in to the **Org-management account** (the same account the
   script is running in) with credentials that have
   `AdministratorAccess`.
2. Pick the home region for Identity Center — typically the same
   region you intend to operate the 3AM workload in (e.g.
   `eu-west-1`). The home region is **permanent**; choose deliberately.
3. Console → **IAM Identity Center** → **Enable**. Wait until the
   landing page shows the instance ARN and identity store ID (usually
   under a minute).
4. Point the script at the home region. Two equivalent options:

   ```sh
   # (a) one-off: set AWS_REGION just for this invocation
   AWS_REGION=eu-west-1 ./single-account-setup.sh apply \
     --breakglass-user bob@acme.example.com

   # (b) persistent for the rest of the CloudShell session
   export AWS_REGION=eu-west-1
   ./single-account-setup.sh apply --breakglass-user bob@acme.example.com
   ```

   Replace `eu-west-1` with whichever home region you picked. The
   `AWS_REGION=… ./script.sh …` prefix form is the quickest fix when
   the failure message is still on screen — copy-paste the exact
   command the script printed.
5. The scripts are idempotent — any work completed before the failure
   is detected and reused on the next run.

> **The "Global" indicator in the AWS console does not apply to
> CloudShell.** Pages like Organizations, IAM, and the AWS Accounts
> list show "Global" in the top-right region selector, but CloudShell
> sessions launched from those pages still run in a specific region
> (whichever region was last selected, or your default — often
> `us-east-1`). The scripts query Identity Center with
> `aws sso-admin list-instances`, which is region-scoped: if you
> enabled Identity Center in `eu-west-1` but CloudShell is in
> `us-east-1`, the script will still report it as "not enabled".
>
> Both scripts log their effective region at the start of preflight
> (`preflight: effective region = …`) and include it in the failure
> message, so the mismatch is obvious. To re-run in a different
> region, prefix with `AWS_REGION=<region>` — the failure message
> spells out the exact command.

**`An error occurred (MalformedPolicyDocument) when calling the CreateRole operation: Invalid principal in policy: "AWS":"arn:aws:iam::033113129683:role/GitHubActions-CustomerDeploy"`**

Phase 5 step 3/6 (`ThreeAM-Deployment role`) writes a trust policy
whose principal is the AxelSpire CI role ARN. AWS IAM resolves that
ARN to the role's internal unique-id at save time and rejects the
trust policy as malformed if no such role exists in the principal's
account.

This means **the AxelSpire CI role does not exist in account
`033113129683`** (or whichever account / role name has been passed
via `--axelspire-ci-account-id` / `--axelspire-ci-role-name`). It is
an AxelSpire-side prerequisite, not a customer-side fix.

To resolve:

1. Confirm with AxelSpire that `GitHubActions-CustomerDeploy` is
   provisioned in account `033113129683`. From any session with
   read access to that account:

   ```sh
   aws iam get-role --role-name GitHubActions-CustomerDeploy \
     --query 'Role.Arn' --output text
   ```

   An empty result or `NoSuchEntity` means the role is missing.
2. Once AxelSpire has created the role, re-run the script. Phase 0
   work and any Phase 5 work completed before the failure is
   idempotently reused; the apply resumes at Phase 5 step 3/6.
3. If you have been pointed at a non-production AxelSpire
   environment (different account ID or a renamed CI role), pass
   `--axelspire-ci-account-id <id>` and `--axelspire-ci-role-name
   <name>` on the next run. The values are also propagated into
   `phase5.axelspire_ci_account_id` / `phase5.axelspire_ci_role_name`
   in the output JSON, so the hand-off to AxelSpire stays
   self-describing.

---

## Hand-off to AxelSpire

The setup script writes a single hand-off file to CloudShell's
persistent home — `$HOME/3am-org-setup-outputs.json` (multi-account)
or `$HOME/3am-single-account-setup-outputs.json` (single-account).
Send that file to AxelSpire over the agreed secure channel. It
contains every ARN/ID that AxelSpire's `customer-onboard` workflow
needs (see [The output JSON](#the-output-json) for the schema).

The **external-ID secret value** is intentionally not in the JSON
(only its ARN, under `phase5.external_id_secret_arn`). It must be
shared separately. To read it:

```sh
# Single-account: read directly from the current account.
aws secretsmanager get-secret-value \
  --secret-id /3am/license/external-id \
  --query SecretString --output text

# Multi-account: assume into the workload account first.
OUTPUTS=$HOME/3am-org-setup-outputs.json
ACCOUNT_ID=$(jq -r .account_id "$OUTPUTS")
PARTITION=$(jq  -r .partition  "$OUTPUTS")
eval "$(aws sts assume-role \
         --role-arn "arn:${PARTITION}:iam::${ACCOUNT_ID}:role/OrganizationAccountAccessRole" \
         --role-session-name read-external-id \
         --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
         --output text \
       | awk '{print "export AWS_ACCESS_KEY_ID="$1"; export AWS_SECRET_ACCESS_KEY="$2"; export AWS_SESSION_TOKEN="$3}')"
aws secretsmanager get-secret-value \
  --secret-id /3am/license/external-id \
  --query SecretString --output text
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

The customer owns and rotates this secret at any time; the setup
script reuses it on re-run rather than regenerating it. See
[`docs/REVIEWING.md`](docs/REVIEWING.md) § "Hand-off" for the channel
specifics.

---

## Verify the apply

These commands run *inside the workload account*. For the
multi-account script, assume `OrganizationAccountAccessRole` first
using the same snippet as the external-ID read above.

```sh
aws iam get-role --role-name ThreeAM-Deployment --query Role.Arn
aws kms describe-key --key-id alias/3am-customer-cmk --query KeyMetadata.Arn
aws s3api head-bucket --bucket "3am-state-$(aws sts get-caller-identity --query Account --output text)-${AWS_REGION:-eu-west-1}"
aws dynamodb describe-table --table-name 3am-state-lock --query Table.TableStatus
aws ssm get-parameters-by-path --path /3am --recursive --query 'Parameters[].Name'
```

All five commands should succeed and the SSM list should contain at
least nine `/3am/...` entries (including the two `/3am/axelspire/*`
paths).

A quick equivalence check directly from the hand-off JSON, without
assuming into the workload account:

```sh
OUTPUTS=$HOME/3am-org-setup-outputs.json
jq -e '
  .phase5
  | (.deployment_role_arn        // "") != ""
  and (.customer_cmk_arn          // "") != ""
  and (.state_bucket_name         // "") != ""
  and (.external_id_secret_arn    // "") != ""
' "$OUTPUTS" >/dev/null \
  && echo "OK: every phase5 ARN is populated" \
  || echo "phase5 incomplete — re-run apply"
```

---

## Reference

### Who runs it

Two patterns are supported. Both result in the same end state — the
customer owns every resource and can revoke AxelSpire's access without
involving AxelSpire.

| Pattern | Who runs it | When it is appropriate |
|---|---|---|
| **Customer-applied** | The customer's platform team, with their own admin credentials, into an account in the customer's AWS Organization. | Default. The customer's security policy requires that no third party perform the initial setup. See [`examples/customer-applied/`](examples/customer-applied/). |
| **AxelSpire-provisioned** | AxelSpire, into a newly-created AWS account inside the AxelSpire AWS Organization. After bootstrap, the account is invited into the customer's Organization and ownership is transferred. | Optional "managed onboarding" — customer does not have to drive the account-vending process. See [`examples/axelspire-provisioned/`](examples/axelspire-provisioned/). |

In both patterns the apply runs **inside the target customer account**.
The AxelSpire CI account is a `Principal` in the role's trust policy,
not a runner of this module.

### What it creates

| Resource | Name | Owned by | Purpose |
|---|---|---|---|
| KMS key | `alias/3am-customer-cmk` | Customer | Encryption-at-rest for customer-owned downstream 3AM resources (audit bucket, SSM SecureStrings, application data). |
| IAM role | `ThreeAM-Deployment` | Customer | Cross-account assume target for AxelSpire CI. No `iam:*`, no `organizations:*`, no broad `s3:*` or `ec2:*`. |
| IAM role policies | `ThreeAM-Deployment-Permissions{,-Ec2,-Extra}` | Customer | Narrow allow-list scoped by ARN prefix `3am-*` and resource tag `Service=3am`. |
| Secrets Manager secret | `/3am/license/external-id` | Customer | 32-byte hex external ID used in the deployment role trust policy. |
| S3 bucket | `3am-state-<account>-<region>` | Customer | Terraform state for every 3AM stack. Versioned, TLS-only, **SSE-KMS using the AxelSpire CI CMK** (kill-switch). |
| DynamoDB table | `3am-state-lock` | Customer | Terraform state locking. PITR enabled, **SSE-KMS using the AxelSpire CI CMK** (kill-switch). |
| SSM parameters | `/3am/{kms,state,iam,bootstrap,axelspire}/...` | Customer | Runtime discovery of the above by downstream stacks. |
| _(reference only)_ KMS key | `alias/3am-ci/<customer-id>` | **AxelSpire CI** | Encrypts customer state + Lambda artifacts. Disabled by AxelSpire at license end to render state and code unreadable without touching customer-owned resources. |
| _(reference only)_ S3 bucket | `3am-ci-artifacts-<ci-account>-<region>` | **AxelSpire CI** | Shared (per-region) bucket holding encrypted Lambda code zips for all enrolled customers. |

### How it fits the wider 3AM platform

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

### Inputs and outputs (Appendix A)

See [`deploy/variables.tf`](deploy/variables.tf) and
[`deploy/outputs.tf`](deploy/outputs.tf). The most important ones:

| Input | Required | Default |
|---|:---:|---|
| `customer_id` | ✅ | — |
| `axelspire_ci_account_id` | ✅ | — |
| `axelspire_artifact_kms_key_arn` | ✅ | — |
| `axelspire_artifact_s3_bucket_arn` | ✅ | — |
| `axelspire_ci_role_name` |  | `GitHubActions-CustomerDeploy` |
| `external_id_secret_arn` |  | `null` |
| `customer_admin_role_arns` |  | `[]` |
| `require_license_session_tag` |  | `true` |
| `kms_key_rotation_enabled` |  | `true` |
| `kms_multi_region` |  | `false` |

`output.handoff_values` is the convenience bundle to share with AxelSpire
(deployment role ARN, CMK ARN, state bucket, lock table, region).

### Security model

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

A security reviewer should be able to read this README,
[`docs/REVIEWING.md`](docs/REVIEWING.md), [`deploy/iam.tf`](deploy/iam.tf)
and [`deploy/kms.tf`](deploy/kms.tf) in about 30 minutes and produce an
informed approval decision.

### Versioning

Semantic versioning. Major bumps for breaking changes to inputs/outputs;
minor for additive changes; patch for documentation and bug fixes.

---

## Appendix A — OpenTofu module (optional)

The CloudShell setup script in [`_scripts/`](_scripts/) is the
recommended way to apply this bootstrap. The OpenTofu module in
[`deploy/`](deploy/) is retained for two purposes:

1. **Customers who run their own IaC** can drive bootstrap through
   their existing Terraform/OpenTofu pipeline rather than CloudShell.
2. **Security reviewers** can read `deploy/*.tf` as the canonical
   declarative form of every resource the script creates (see
   [`docs/REVIEWING.md`](docs/REVIEWING.md)).

See [`examples/customer-applied/`](examples/customer-applied/) for the
full wrapping example, and
[`examples/axelspire-provisioned/`](examples/axelspire-provisioned/)
for the managed-onboarding variant (AxelSpire creates the account
first, then transfers it to the customer's Organization).

### A.1 — write `acme.tfvars`

```hcl
customer_id                      = "acme-corp"
region                           = "eu-west-1"
axelspire_ci_account_id          = "033113129683"
customer_admin_role_arns         = [
  "arn:aws:iam::123456789012:role/PlatformAdmin",
  "arn:aws:iam::123456789012:role/BreakGlass",
]
axelspire_artifact_kms_key_arn   = "arn:aws:kms:eu-west-1:033113129683:alias/3am-ci/acme-corp"
axelspire_artifact_s3_bucket_arn = "arn:aws:s3:::3am-ci-artifacts-033113129683-eu-west-1"
```

### A.2 — apply

```sh
cd examples/customer-applied
tofu init
tofu apply -var-file=acme.tfvars
```

### A.3 — capture the hand-off bundle

```sh
tofu output -json handoff_values > handoff.json
```

Then go to [Hand-off to AxelSpire](#hand-off-to-axelspire).

---

## Appendix B — Manual AWS CLI walkthrough (reference only)

Step-by-step `aws` CLI v2 reproduction of the OpenTofu module. The
setup script in [`_scripts/`](_scripts/) executes these exact API
calls internally, so most readers will never need this. Use it to:

- Audit what the script does without reading the bash source.
- Recover individual resources manually if a partial failure cannot
  be remediated by re-running the script.
- Adopt the resulting resources into a different IaC tool via `import`
  operations.

The resulting resources are identical to Appendix A — same names,
same policies, same tags — so a subsequent `tofu import` is possible
if the customer later adopts OpenTofu.

This walkthrough assumes the workload account, region, and the
AxelSpire-supplied hand-off values are already set in environment
variables (`ACCOUNT_ID`, `AWS_REGION`, `PARTITION`, `CUSTOMER_ID`,
`AXELSPIRE_CI_ACCOUNT_ID`, `AXELSPIRE_CI_ROLE_NAME`,
`CUSTOMER_ADMIN_ROLE_ARNS`, `AXELSPIRE_ARTIFACT_KMS_KEY_ARN`,
`AXELSPIRE_ARTIFACT_S3_BUCKET_ARN`, `EXTERNAL_ID_SECRET_ARN`); the
setup script derives all of these automatically.

> Run the steps in order. Each step is idempotent within itself but
> assumes the previous step has succeeded. Re-running a step that
> already created its resource will fail with `EntityAlreadyExists` /
> `BucketAlreadyOwnedByYou` — that is expected and safe; skip to the
> next step.

### B.1 — common tags

```sh
export COMMON_TAGS_JSON=$(jq -cn \
  --arg customer "$CUSTOMER_ID" \
  '[
    {Key:"Service",          Value:"3am"},
    {Key:"CustomerId",       Value:$customer},
    {Key:"ManagedBy",        Value:"3am-infra-bootstrap"},
    {Key:"BootstrapVersion", Value:"0.1.0"}
  ]')
```

### B.2 — create the deployment IAM role (trust policy only)

The KMS key policy will reference this role's ARN, so the role must exist
first. Permissions are attached in step B.5 after the KMS key and state
backend exist.

```sh
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowAxelspireCIAssumeRole",
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:${PARTITION}:iam::${AXELSPIRE_CI_ACCOUNT_ID}:role/${AXELSPIRE_CI_ROLE_NAME}"
    },
    "Action": ["sts:AssumeRole", "sts:TagSession"],
    "Condition": {
      "StringLike": {
        "sts:RoleSessionName": ["3am-*", "tg-*"]
      },
      "StringEquals": {
        "sts:ExternalId":                    "$(aws secretsmanager get-secret-value --secret-id "$EXTERNAL_ID_SECRET_ARN" --query SecretString --output text)",
        "aws:RequestTag/LicenseValid":       "true"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name ThreeAM-Deployment \
  --description "Cross-account role assumed by AxelSpire CI to deploy 3AM resources for ${CUSTOMER_ID}." \
  --max-session-duration 3600 \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --tags "$(echo "$COMMON_TAGS_JSON" | jq -c '.')"

export DEPLOYMENT_ROLE_ARN=$(aws iam get-role \
  --role-name ThreeAM-Deployment --query Role.Arn --output text)
```

> If the customer's policy does **not** require the `LicenseValid` session
> tag, remove the `aws:RequestTag/LicenseValid` line from the Condition
> block. Likewise, omit the `sts:ExternalId` line if no external ID is in
> use. This mirrors the `require_license_session_tag` and
> `external_id_secret_arn` variables in `deploy/variables.tf`.

### B.3 — create the customer-managed CMK and alias

```sh
ADMINS_JSON=$(echo "$CUSTOMER_ADMIN_ROLE_ARNS" | jq -c '.')

cat > /tmp/kms-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableIAMUserPermissions",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:${PARTITION}:iam::${ACCOUNT_ID}:root"},
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCustomerAdminsKeyManagement",
      "Effect": "Allow",
      "Principal": {"AWS": ${ADMINS_JSON}},
      "Action": [
        "kms:Create*","kms:Describe*","kms:Enable*","kms:List*","kms:Put*",
        "kms:Update*","kms:Revoke*","kms:Disable*","kms:Get*","kms:Delete*",
        "kms:TagResource","kms:UntagResource",
        "kms:ScheduleKeyDeletion","kms:CancelKeyDeletion"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowAxelspireDeploymentRoleDataPlane",
      "Effect": "Allow",
      "Principal": {"AWS": "${DEPLOYMENT_ROLE_ARN}"},
      "Action": [
        "kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
        "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowLambdaServiceUseInThisAccount",
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": [
        "kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
        "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey","kms:CreateGrant"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService":     "lambda.${AWS_REGION}.amazonaws.com",
          "kms:CallerAccount":  "${ACCOUNT_ID}"
        }
      }
    }
  ]
}
EOF

export KMS_KEY_ID=$(aws kms create-key \
  --description "3AM customer-managed CMK for ${CUSTOMER_ID}" \
  --policy file:///tmp/kms-policy.json \
  --tags "$(echo "$COMMON_TAGS_JSON" | jq -c '[.[] | {TagKey:.Key, TagValue:.Value}]')" \
  --query KeyMetadata.KeyId --output text)

aws kms enable-key-rotation --key-id "$KMS_KEY_ID"

aws kms create-alias \
  --alias-name alias/3am-customer-cmk \
  --target-key-id "$KMS_KEY_ID"

export KMS_KEY_ARN=$(aws kms describe-key --key-id "$KMS_KEY_ID" \
  --query KeyMetadata.Arn --output text)
```

### B.4 — create the state backend (S3 + DynamoDB)

```sh
export STATE_BUCKET="3am-state-${ACCOUNT_ID}-${AWS_REGION}"

# Bucket (the LocationConstraint flag is required for every region except us-east-1).
if [ "$AWS_REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$STATE_BUCKET"
else
  aws s3api create-bucket --bucket "$STATE_BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi

aws s3api put-bucket-tagging --bucket "$STATE_BUCKET" \
  --tagging "TagSet=$(echo "$COMMON_TAGS_JSON" | jq -c '.')"

aws s3api put-bucket-ownership-controls --bucket "$STATE_BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration "$(jq -cn --arg arn "$AXELSPIRE_ARTIFACT_KMS_KEY_ARN" '{
    Rules:[{
      ApplyServerSideEncryptionByDefault:{SSEAlgorithm:"aws:kms",KMSMasterKeyID:$arn},
      BucketKeyEnabled:true
    }]
  }')"

aws s3api put-bucket-lifecycle-configuration --bucket "$STATE_BUCKET" \
  --lifecycle-configuration '{
    "Rules":[{
      "ID":"transition-noncurrent-to-glacier","Status":"Enabled","Filter":{},
      "NoncurrentVersionTransitions":[{"NoncurrentDays":90,"StorageClass":"GLACIER"}],
      "NoncurrentVersionExpiration":{"NoncurrentDays":365}
    }]
  }'

aws s3api put-bucket-policy --bucket "$STATE_BUCKET" --policy "$(jq -cn \
  --arg arn "arn:${PARTITION}:s3:::${STATE_BUCKET}" '{
    Version:"2012-10-17",
    Statement:[{
      Sid:"DenyInsecureTransport", Effect:"Deny", Principal:"*", Action:"s3:*",
      Resource:[$arn, ($arn+"/*")],
      Condition:{Bool:{"aws:SecureTransport":"false"}}
    }]
  }')"

# DynamoDB lock table.
aws dynamodb create-table \
  --table-name 3am-state-lock \
  --billing-mode PAY_PER_REQUEST \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema           AttributeName=LockID,KeyType=HASH \
  --sse-specification    "Enabled=true,SSEType=KMS,KMSMasterKeyId=${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" \
  --tags "$(echo "$COMMON_TAGS_JSON" | jq -c '.')"

aws dynamodb wait table-exists --table-name 3am-state-lock

aws dynamodb update-continuous-backups \
  --table-name 3am-state-lock \
  --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true

export STATE_LOCK_TABLE_ARN=$(aws dynamodb describe-table \
  --table-name 3am-state-lock --query Table.TableArn --output text)
export STATE_BUCKET_ARN="arn:${PARTITION}:s3:::${STATE_BUCKET}"
```

### B.5 — attach the three inline permission policies

These mirror, statement-for-statement, [`deploy/iam.tf`](deploy/iam.tf),
[`deploy/iam-permissions-ec2.tf`](deploy/iam-permissions-ec2.tf), and
[`deploy/iam-permissions-extra.tf`](deploy/iam-permissions-extra.tf).

```sh
# ---- ThreeAM-Deployment-Permissions (trust-anchor resources) ----
cat > /tmp/perms.json <<EOF
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Sid":"LambdaOn3amFunctions","Effect":"Allow","Action":"lambda:*",
      "Resource":"arn:${PARTITION}:lambda:*:${ACCOUNT_ID}:function:3am-*"
    },
    {
      "Sid":"KmsDataPlaneOnCustomerCmk","Effect":"Allow",
      "Action":["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext","kms:DescribeKey"],
      "Resource":"${KMS_KEY_ARN}"
    },
    {
      "Sid":"KmsDataPlaneOnAxelspireArtifactCmk","Effect":"Allow",
      "Action":["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext","kms:DescribeKey"],
      "Resource":"${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
    },
    {
      "Sid":"S3OnStateBucket","Effect":"Allow",
      "Action":["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:DeleteObject",
                "s3:ListBucket","s3:ListBucketVersions","s3:GetBucketVersioning",
                "s3:GetEncryptionConfiguration","s3:GetBucketLocation"],
      "Resource":["${STATE_BUCKET_ARN}","${STATE_BUCKET_ARN}/*"]
    },
    {
      "Sid":"S3ReadOnAxelspireArtifactBucket","Effect":"Allow",
      "Action":["s3:GetObject","s3:GetObjectVersion","s3:ListBucket","s3:GetBucketLocation"],
      "Resource":["${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}","${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}/*"]
    },
    {
      "Sid":"DynamoDBOnStateLockTable","Effect":"Allow",
      "Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:DeleteItem","dynamodb:DescribeTable"],
      "Resource":"${STATE_LOCK_TABLE_ARN}"
    }
  ]
}
EOF
aws iam put-role-policy --role-name ThreeAM-Deployment \
  --policy-name ThreeAM-Deployment-Permissions \
  --policy-document file:///tmp/perms.json

# ---- ThreeAM-Deployment-Permissions-Ec2 ----
cat > /tmp/perms-ec2.json <<EOF
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Sid":"Ec2VpcRead","Effect":"Allow",
      "Action":["ec2:DescribeVpcs","ec2:DescribeSubnets","ec2:DescribeRouteTables",
                "ec2:DescribeNetworkInterfaces","ec2:DescribeSecurityGroups",
                "ec2:DescribeAvailabilityZones","ec2:DescribeRegions","ec2:DescribeAccountAttributes"],
      "Resource":"*"
    },
    {
      "Sid":"Ec2SecurityGroupWriteOnTagged","Effect":"Allow",
      "Action":["ec2:AuthorizeSecurityGroupIngress","ec2:AuthorizeSecurityGroupEgress",
                "ec2:RevokeSecurityGroupIngress","ec2:RevokeSecurityGroupEgress",
                "ec2:CreateTags","ec2:DeleteTags"],
      "Resource":"arn:${PARTITION}:ec2:*:${ACCOUNT_ID}:security-group/*",
      "Condition":{"StringEquals":{"aws:ResourceTag/Service":"3am"}}
    },
    {
      "Sid":"Ec2SecurityGroupCreate","Effect":"Allow",
      "Action":"ec2:CreateSecurityGroup","Resource":"*",
      "Condition":{"StringEquals":{"aws:RequestTag/Service":"3am"}}
    }
  ]
}
EOF
aws iam put-role-policy --role-name ThreeAM-Deployment \
  --policy-name ThreeAM-Deployment-Permissions-Ec2 \
  --policy-document file:///tmp/perms-ec2.json

# ---- ThreeAM-Deployment-Permissions-Extra (SSM / Logs / APIGW / R53 / ACM) ----
cat > /tmp/perms-extra.json <<EOF
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Sid":"SsmReadOn3amParameters","Effect":"Allow",
      "Action":["ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath","ssm:DescribeParameters"],
      "Resource":"arn:${PARTITION}:ssm:*:${ACCOUNT_ID}:parameter/3am/*"
    },
    {
      "Sid":"SsmWriteOn3amParameters","Effect":"Allow",
      "Action":["ssm:PutParameter","ssm:DeleteParameter","ssm:DeleteParameters",
                "ssm:AddTagsToResource","ssm:RemoveTagsFromResource","ssm:LabelParameterVersion"],
      "Resource":"arn:${PARTITION}:ssm:*:${ACCOUNT_ID}:parameter/3am/*"
    },
    {
      "Sid":"LogsOn3amGroups","Effect":"Allow",
      "Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:DeleteLogGroup",
                "logs:DescribeLogGroups","logs:DescribeLogStreams","logs:PutLogEvents",
                "logs:PutRetentionPolicy","logs:TagResource","logs:UntagResource","logs:AssociateKmsKey"],
      "Resource":[
        "arn:${PARTITION}:logs:*:${ACCOUNT_ID}:log-group:/aws/lambda/3am-*",
        "arn:${PARTITION}:logs:*:${ACCOUNT_ID}:log-group:/aws/lambda/3am-*:*",
        "arn:${PARTITION}:logs:*:${ACCOUNT_ID}:log-group:/3am/*",
        "arn:${PARTITION}:logs:*:${ACCOUNT_ID}:log-group:/3am/*:*"
      ]
    },
    {
      "Sid":"ApiGatewayOnTaggedResources","Effect":"Allow",
      "Action":["apigateway:GET","apigateway:POST","apigateway:PUT","apigateway:PATCH",
                "apigateway:DELETE","apigateway:TagResource","apigateway:UntagResource"],
      "Resource":"arn:${PARTITION}:apigateway:*::/*",
      "Condition":{"StringEquals":{"aws:ResourceTag/Service":"3am"}}
    },
    {
      "Sid":"Route53Read","Effect":"Allow",
      "Action":["route53:ListHostedZones","route53:GetHostedZone",
                "route53:ListResourceRecordSets","route53:GetChange"],
      "Resource":"*"
    },
    {
      "Sid":"Route53WriteOnTaggedZones","Effect":"Allow",
      "Action":["route53:ChangeResourceRecordSets","route53:ChangeTagsForResource"],
      "Resource":"arn:${PARTITION}:route53:::hostedzone/*",
      "Condition":{"StringEquals":{"aws:ResourceTag/3am-managed":"true"}}
    },
    {
      "Sid":"AcmOnTaggedCertificates","Effect":"Allow",
      "Action":["acm:DescribeCertificate","acm:GetCertificate","acm:ListTagsForCertificate",
                "acm:DeleteCertificate","acm:AddTagsToCertificate","acm:RemoveTagsFromCertificate"],
      "Resource":"*",
      "Condition":{"StringEquals":{"aws:ResourceTag/Service":"3am"}}
    },
    {
      "Sid":"AcmListAndRequest","Effect":"Allow",
      "Action":["acm:ListCertificates","acm:RequestCertificate"],
      "Resource":"*"
    }
  ]
}
EOF
aws iam put-role-policy --role-name ThreeAM-Deployment \
  --policy-name ThreeAM-Deployment-Permissions-Extra \
  --policy-document file:///tmp/perms-extra.json
```

### B.6 — publish `/3am/*` SSM parameters

```sh
TAGS_SSM=$(echo "$COMMON_TAGS_JSON" | jq -c '.')

put_param () {  # name, value, type
  aws ssm put-parameter --name "$1" --value "$2" --type "$3" --overwrite \
    >/dev/null
  aws ssm add-tags-to-resource --resource-type Parameter \
    --resource-id "$1" --tags "$TAGS_SSM" >/dev/null
}

put_param /3am/kms/customer-cmk-arn               "$KMS_KEY_ARN"                       String
put_param /3am/kms/customer-cmk-id                "$KMS_KEY_ID"                        String
put_param /3am/state/bucket-name                  "$STATE_BUCKET"                      String
put_param /3am/state/lock-table-name              "3am-state-lock"                     String
put_param /3am/iam/deployment-role-arn            "$DEPLOYMENT_ROLE_ARN"               String
put_param /3am/axelspire/artifact-kms-key-arn     "$AXELSPIRE_ARTIFACT_KMS_KEY_ARN"    String
put_param /3am/axelspire/artifact-s3-bucket-arn   "$AXELSPIRE_ARTIFACT_S3_BUCKET_ARN"  String
put_param /3am/bootstrap/version                  "0.1.0"                              String
put_param /3am/bootstrap/applied-at               "$(date -u +%Y-%m-%dT%H:%M:%SZ)"     String
```

### B.7 — build the hand-off bundle

```sh
jq -n \
  --arg customer_id        "$CUSTOMER_ID" \
  --arg region             "$AWS_REGION" \
  --arg account_id         "$ACCOUNT_ID" \
  --arg role_arn           "$DEPLOYMENT_ROLE_ARN" \
  --arg cmk_arn            "$KMS_KEY_ARN" \
  --arg state_bucket       "$STATE_BUCKET" \
  --arg state_lock_table   "3am-state-lock" \
  --arg artifact_kms       "$AXELSPIRE_ARTIFACT_KMS_KEY_ARN" \
  --arg artifact_bucket    "$AXELSPIRE_ARTIFACT_S3_BUCKET_ARN" \
  '{
    customer_id:                       $customer_id,
    region:                            $region,
    account_id:                        $account_id,
    deployment_role_arn:               $role_arn,
    customer_kms_key_arn:              $cmk_arn,
    state_bucket_name:                 $state_bucket,
    state_lock_table_name:             $state_lock_table,
    axelspire_artifact_kms_key_arn:    $artifact_kms,
    axelspire_artifact_s3_bucket_arn:  $artifact_bucket,
    bootstrap_version:                 "0.1.0"
  }' > handoff.json
```

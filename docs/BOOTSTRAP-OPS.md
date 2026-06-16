# Bootstrap operations manual — AxelSpire side

**Audience:** AxelSpire platform / ops engineers driving
`customer-org-setup.sh` or `single-account-setup.sh` for a new (or
recovering) customer. The customer-facing recipe lives in
`README.md`; this document is the operator-side counterpart.

This is the bootstrap-side companion to
`3am-deployments/docs/CUSTOMER-ONBOARDING-OPS.md` (which picks up after
the bootstrap JSON is in hand). For the full end-to-end story across
both repos see `ONBOARDING-FLOW.md` at the workspace root.

---

## 1. When this manual applies

Three scenarios. They share most steps; differences are called out
inline.

| Scenario | Who runs the script | Operator's role |
|---|---|---|
| **AxelSpire-runs** | AxelSpire (this doc's reader) using a delegated admin in the customer Org | Owns every step |
| **Pair-run** | Customer at the keyboard, AxelSpire on a screen-share | Verify inputs, capture the JSON, drive troubleshooting |
| **Recovery / re-run** | AxelSpire, against an account that was previously bootstrapped | Re-resolve outputs and reconcile, do *not* re-create resources |

The customer-only path ("customer reads `README.md`, runs the script,
emails JSON to AxelSpire") is not covered here — `README.md` is the
canonical doc for that.

---

## 2. Choosing the variant

| Script | Use when | Key consequence |
|---|---|---|
| `customer-org-setup.sh` (multi-account) | Customer has, or is willing to use, an AWS Organization. Recommended for production. | Creates a new child account under a `3AM` OU; runs Phase 5 in the child by assuming `OrganizationAccountAccessRole`. Blast radius is the child account only. |
| `single-account-setup.sh` (single-account) | Customer has one AWS account total (typical POC / small customer) and is unwilling or unable to set up Organizations. | No new account is created. Phase 0 (SCPs / Identity Center) and Phase 5 (deployment role, CMK, state, secret) run in the same account. Coupling is intentional and irreversible without a re-bootstrap. |

If the customer might grow into an Org-based setup later, push for the
multi-account variant from day one — there is no automated migration
from single-account to multi-account.

---

## 3. Prerequisites

### 3.1 Operator authentication

- AWS SSO session for the **customer's** Org-management account (or the
  account itself for single-account variant). The session must hold an
  `AdministratorAccess`-equivalent permission set in that account.
- For AxelSpire-runs / pair-runs the customer typically delegates this
  via Identity Center or a temporary IAM user. Either is fine; the
  script does not care how the caller authenticated, only that the
  caller can hit `organizations:*`, `sso-admin:*`, `iam:*`, `kms:*`,
  `s3:*`, `dynamodb:*`, `secretsmanager:*`, `ssm:*`.
- For local-laptop runs against macOS see
  `3am-deployments/docs/AWS-AUTH-MACOS.md` for the SSO-login recipe
  (`Token has expired` is the most common symptom of a stale session).

### 3.2 Tools

- `awscli` v2.x — `aws --version` should report `aws-cli/2.`
- `jq` — any 1.6+
- `bash` 4+ (`bash 5+` on macOS via Homebrew; default `/bin/bash` is
  3.2 and will not work)

The script itself runs ideally in **AWS CloudShell** from the customer's
Org-management account — that side-steps every tooling and credential
concern in one go.

### 3.3 SSO home region vs. deployment region

Identity Center is a **single-region** service: an Org has exactly one
IDC home region (often `us-east-1`), set when IDC was first enabled
and effectively immutable. All `sso-admin:*` / `identitystore:*` calls
must target that region. The customer's workload (state bucket, lock
table, customer CMK, external-ID secret) lives in the **deployment
region**, which may differ.

The script decouples these:

- `AWS_REGION` (or `AWS_DEFAULT_REGION` / `aws configure get region`)
  selects the **IDC / Organizations** region. Set it to the IDC home
  region; if IDC is enabled elsewhere, preflight fails with a clear
  message telling you which region to re-run from.
- `--deployment-region <region>` selects the **workload** region. It
  defaults to `AWS_REGION` (single-region orgs need not pass it). It
  must appear in `--allowed-regions`. The KMS ARN passed via
  `--axelspire-artifact-kms-key-arn` must be the same-region MRK leaf;
  preflight enforces the region match.

`customer-org-setup.sh` additionally pivots `AWS_REGION` to the
deployment region after assuming into the child account, so all
Phase 5 AWS CLI calls (KMS, Secrets Manager, S3, DynamoDB, SSM)
target the right regional endpoint regardless of where IDC lives.
`single-account-setup.sh` performs the same pivot around Phase 5.

### 3.4 Inputs from the intake form

Before running, collect from the customer (intake form §1, §3):

| Bootstrap flag | Source |
|---|---|
| `--customer-name` | Intake §1 customer legal name |
| `--customer-id` | Intake §1 customer ID slug |
| `--account-email` *(multi-account only)* | Intake §3 root email for the new account |
| `--platform-admin-user` | Intake §3 technical contact email (or designated platform admin) |
| `--breakglass-user` | Intake §3 break-glass contact email |
| `--allowed-regions` | Intake §3 primary region + any pre-approved secondaries |
| `--deployment-region` *(optional)* | Intake §3 primary deployment region — pass only when it differs from the IDC home region the script's `AWS_REGION` points at |

The CI CMK ARN is **not** an intake-form input — it comes from AxelSpire
out-of-band, *after* the customer-onboard PR has merged and
`platform-deploy.yml` has applied the per-customer `customer-ci-key`
primary and `customer-ci-key-replica` leaves. `--axelspire-artifact-kms-key-arn`
is **required** on every `apply`: it must be the key-ID ARN
(`arn:<partition>:kms:<region>:<ci-acct>:key/<uuid>`, never an alias
ARN) of the MRK *replica* whose region equals the customer's deployment
region. The script enforces both rules; the customer cannot proceed
without an AxelSpire-issued value.

---

## 4. Pre-flight checks

Run the script's own check before any apply:

```bash
./customer-org-setup.sh preflight \
  --customer-name "Acme Corp" --customer-id acme-corp \
  --account-email aws-3am@acme.example.com \
  --platform-admin-user alice@acme.example.com \
  --breakglass-user bob@acme.example.com
```

`preflight` runs every input-validation and existence check the `apply`
path runs, but performs zero AWS writes. Re-run after fixing any error
it reports.

Additional manual checks worth doing once:

- **Account already enrolled?** Search the `3am-customer-intake` and
  `3am-customer-registry` DynamoDB tables in the AxelSpire CI account
  for the `customer_id` slug. If it already exists, you are in the
  recovery scenario — read §7 before continuing.
- **OU placement.** `customer-org-setup.sh` will create or reuse an OU
  called `3AM` (overridable via `--ou-name`). Verify the customer's
  Org doesn't already have an SCP at the root that conflicts (e.g.
  region-deny with a different allow-list).
- **KMS alias collisions.** The script creates `alias/3am-customer-cmk`
  inside the child / target account. If the customer already has
  something with that alias, the apply will fail — investigate first.
- **GitHub OIDC provider.** The Phase 5 deployment role trusts the
  AxelSpire CI account, not GitHub directly, so no OIDC provider is
  needed in the customer account. If the customer has one already, it
  is harmless.

---

## 5. Running `customer-org-setup.sh`

Standard apply, customer-Org-management context:

```bash
./customer-org-setup.sh apply \
  --customer-name "Acme Corp" \
  --customer-id acme-corp \
  --account-email aws-3am@acme.example.com \
  --platform-admin-user alice@acme.example.com \
  --breakglass-user bob@acme.example.com \
  --allowed-regions eu-west-1,us-east-1 \
  --axelspire-artifact-kms-key-arn arn:aws:kms:us-east-1:033113129683:key/<uuid>
```

The `--axelspire-artifact-kms-key-arn` value comes from AxelSpire (the
key-ID ARN of the customer-region MRK replica; see §3.4). The script
rejects alias ARNs and ARNs whose region does not equal the customer's
deployment region.

The apply is idempotent and resumable: every step is "list → create if
missing → reuse". A partial failure can be cleared by fixing the cause
and re-running the same command. See `--help` for every flag.

The script tags the newly-created child account with `CustomerId` and
`CustomerName` Organizations tags. These exist purely so a later
`outputs-json` invocation from a fresh shell can re-derive the slug
without the operator passing `--customer-id` again (see §7).

Capture the output JSON to a stable path:

```bash
./customer-org-setup.sh outputs-json > "$HOME/3am-org-setup-outputs.json"
```

`outputs-json` re-resolves every field against live AWS state and is
safe to run any number of times.

---

## 6. Running `single-account-setup.sh`

Same idea, run from inside the workload account (not a separate
Org-management account):

```bash
./single-account-setup.sh apply \
  --customer-name "Acme Corp" \
  --customer-id acme-corp \
  --platform-admin-user alice@acme.example.com \
  --breakglass-user bob@acme.example.com \
  --allowed-regions eu-west-1,us-east-1 \
  --axelspire-artifact-kms-key-arn arn:aws:kms:us-east-1:033113129683:key/<uuid>
```

`--axelspire-artifact-kms-key-arn` is required (§3.4 / §5).

Differences from `customer-org-setup.sh` worth knowing:

| Difference | Detail |
|---|---|
| No `--account-email` | No account is created. |
| `--skip-org` | Phase 0 (SCPs / Identity Center) is skipped; useful when re-running just Phase 5 in an already-configured account. |
| Output filename | `3am-single-account-setup-outputs.json` instead of `3am-org-setup-outputs.json`. |
| JSON schema | Identical to the multi-account schema (same `phase0` / `phase5` shape) — see `README.md → The output JSON`. The deployments side does not need to know which variant produced the file. |

---

## 7. Recovery and idempotency

Re-running `apply` against an already-bootstrapped account is the
**recovery procedure**. There is no separate `destroy` /
`rollback` subcommand; the script is designed so re-application
converges to the same state without rebuilding resources.

For the recovery scenario specifically:

```bash
AWS_REGION=us-east-1 ./customer-org-setup.sh outputs-json \
  > "$HOME/3am-org-setup-outputs.json"
```

This works with **no flags** if the original `apply` ran the
account-tagging step — the script reads `CustomerId` / `CustomerName`
back from Organizations tags on the child account, then re-resolves
every Phase 5 value by assuming
`OrganizationAccountAccessRole`. If the tags are missing (older
bootstraps pre-tagging), pass `--customer-id` explicitly:

```bash
./customer-org-setup.sh outputs-json --customer-id acme-corp \
  > "$HOME/3am-org-setup-outputs.json"
```

If `outputs-json` shows empty `phase5.*` fields, the Phase 5 step in
the child account never completed. Re-run `apply` with the original
flags — every step that already succeeded is a no-op.

---

## 8. Verifying the output JSON

Open the JSON and confirm:

```bash
jq '{customer_id, account_id, region, partition,
     phase0_admin_roles: (.phase0.customer_admin_role_arns | length),
     phase5_complete: (
       .phase5 |
       (.deployment_role_arn // "") != "" and
       (.customer_cmk_arn // "")    != "" and
       (.state_bucket_name // "")   != "" and
       (.external_id_secret_arn // "") != ""
     )}' "$HOME/3am-org-setup-outputs.json"
```

Expected: `customer_id` matches the intake slug, `phase0_admin_roles`
is `2` (PlatformAdmin + BreakGlass), `phase5_complete` is `true`.
If any phase5 field is empty, re-run `apply`.

### 8.1 Where each JSON field is consumed downstream

This is the link with `customer-scaffold.sh` (which runs inside the
`customer-onboard.yml` workflow on the deployments side — you do *not*
invoke it yourself). The fields below become workflow inputs that
`customer-scaffold.sh` writes into the customer's leaves and the CI
key leaf.

| JSON field | Becomes | At |
|---|---|---|
| `.customer_id` | `customer_id` workflow input → scaffold leaf dir name | `customer-onboard.yml` |
| `.account_id` | `aws_account_id` workflow input → `customer.hcl.aws_account_id` | `customer-onboard.yml` |
| `.region` | `initial_region` workflow input → leaf region dir | `customer-onboard.yml` |
| `.phase0.customer_admin_role_arns` | `customer_admin_roles` CSV input → `customer.hcl` | `customer-onboard.yml` |
| `.phase5.axelspire_artifact_kms_key_arn` | Audit echo — must equal the value AxelSpire issued (replica leaf's `terragrunt output kms_key_arn`) | `CUSTOMER-ONBOARDING-OPS.md §3` |
| Everything else (`.phase5.deployment_role_arn`, `.phase5.state_bucket_name`, …) | Informational — written inline to DynamoDB attribute `bootstrap_json` for audit/recovery | `customer-intake-write.sh --from-org-setup` |

The remaining three scaffold inputs (`vpc_cidr`, `license_tier`,
`approval_tier`) come from the **intake form**
(`3am-deployments/customers/_template/INTAKE.md` §2 / §3), not the
bootstrap JSON.

### 8.2 Spotting an unpopulated template

If the JSON's `customer_id` is the literal string `__CUSTOMER_ID__` or
`example-customer`, the `apply` was never run with real arguments and
you are looking at the template fallback. `customer-intake-write.sh`
will refuse to write a row in that case with a clear error — but it is
cheaper to spot it here.

---

## 9. Hand-off to the deployments side

After a successful `apply` and a clean `outputs-json`, the JSON is the
only thing that crosses the repo boundary into `3am-deployments`. The
hand-off is three commands in this order:

**a. Write the intake row** — records commercial metadata and stores
the bootstrap JSON inline under the `bootstrap_json` attribute:

```bash
cd 3am-deployments
./_scripts/customer-intake-write.sh \
  --from-org-setup "$HOME/3am-org-setup-outputs.json"
```

On success, the script prints a copy-paste-ready
`gh workflow run customer-onboard.yml` command with `customer_id`,
`aws_account_id`, `initial_region`, and `customer_admin_roles`
pre-filled from the JSON.

**b. Fill in the contract-derived blanks and trigger the workflow** —
`vpc_cidr`, `license_tier`, and `approval_tier` come from the intake
form, not the bootstrap. Paste the printed command, fill those three,
and run it. The workflow invokes `_scripts/customer-scaffold.sh`
internally to render `customers/<id>/<region>/` and the CI key leaf,
then opens a PR.

**c. Continue with `CUSTOMER-ONBOARDING-OPS.md` §4 onward** for PR
review and the `platform-deploy` apply that creates the per-customer
CI CMK.

> In the normal flow you do not invoke `customer-scaffold.sh` yourself
> — `customer-onboard.yml` runs it against repository-pinned templates.
> For template-debug or smoke-test scenarios the local invocation is
> documented in
> `3am-deployments/docs/CUSTOMER-ONBOARDING-OPS.md` §4.1; the working-copy
> output from a local run is for inspection only and must not be PR'd.

### 9.1 External-ID secret

The external-ID **value** is never in the bootstrap JSON; only its
ARN is (`.phase5.external_id_secret_arn`). The customer-side script
generates a fresh value at `apply` time and stores it in the customer
account's Secrets Manager. AxelSpire fetches it over a separate
channel — see `README.md → Hand-off to AxelSpire` for the customer
side and `CUSTOMER-ONBOARDING-OPS.md` for where to put it on the
platform side.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Token has expired` on any AWS call | Stale SSO session | `aws sso login --profile <profile>` — see `3am-deployments/docs/AWS-AUTH-MACOS.md` |
| `IAM Identity Center is not enabled in region '<X>'` | Identity Center is enabled in a different region | Re-run with `AWS_REGION=<sso-home-region>` (often `us-east-1`) |
| `unknown argument: —customer-id` (em-dash) | macOS "Smart Dashes" converted `--` to `—` while you copy-pasted | Disable Smart Dashes (System Settings → Keyboard → Text Input → Edit) or retype the dashes in a plain editor |
| `AlreadyExistsException` on KMS alias `alias/3am-customer-cmk` | Customer account already has that alias from a prior unrelated workload | Pick a different alias prefix (rare; usually means the customer was bootstrapped before — see §7) |
| `AccessDeniedException` calling `OrganizationAccountAccessRole` from Org-mgmt | Either the role was deleted in the child account, or the trust was edited | Restore the role from the AWS Organizations console; the script does not heal this |
| Phase 5 fails with SCP denial | Customer Org has an SCP forbidding `kms:CreateKey` / `iam:CreateRole` / etc. in the child | Customer ops must adjust the SCP. AxelSpire cannot bypass it |
| `outputs-json` shows empty `phase5.*` | Phase 5 never ran (most common: `--skip-bootstrap` was passed, or assume-role into child failed) | Re-run `apply` with the original flags; every successful step is a no-op |
| Intake-write rejects the JSON with "unpopulated template" | The JSON's `customer_id` is `__CUSTOMER_ID__` or similar placeholder | Confirm you captured the *real* output of `outputs-json` to the path you passed |

For platform-side failures (PR scaffolding, `platform-deploy` apply,
`customer-deploy` apply) see
`3am-deployments/docs/CUSTOMER-ONBOARDING-OPS.md` §11.

---

## 11. Reference

### 11.1 Scripts in scope

| Script | Where | Who invokes |
|---|---|---|
| `customer-org-setup.sh` | `3am-infra-bootstrap/_scripts/` | Operator, per this doc |
| `single-account-setup.sh` | `3am-infra-bootstrap/_scripts/` | Operator, per this doc |
| `customer-intake-write.sh` | `3am-deployments/_scripts/` | Operator, via §9 hand-off |
| `customer-scaffold.sh` | `3am-deployments/_scripts/` | `customer-onboard.yml` workflow, indirectly — not by you |

### 11.2 Related documents

| Document | What it covers |
|---|---|
| `3am-infra-bootstrap/README.md` | Customer-facing recipe and output JSON schema |
| `ONBOARDING-FLOW.md` (workspace root) | Full end-to-end flow across both repos, both actors |
| `3am-deployments/docs/CUSTOMER-ONBOARDING-OPS.md` | AxelSpire ops manual for the deployments side (PR, workflow, apply) |
| `3am-deployments/docs/AWS-AUTH-MACOS.md` | Operator SSO / MFA setup on macOS |
| `3am-deployments/customers/_template/INTAKE.md` | Intake-form template (per-customer audit record) |
| `CI-ACCOUNT-SETUP.md` (workspace root) | One-time AxelSpire CI account inventory and setup |

### 11.3 Output JSON schema

Authoritative reference:
`3am-infra-bootstrap/README.md → The output JSON`. The schema is
identical for both `customer-org-setup.sh` and
`single-account-setup.sh`; only the filename differs.

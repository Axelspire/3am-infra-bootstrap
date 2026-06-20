# Security review walkthrough

Intended for the customer's security team. Read the
[README](../README.md) first, then this document in order. Every claim
in this file is checkable against the Terraform source — file and
resource references are given in square brackets.

## 1. What AxelSpire can and cannot do

After this module is applied, AxelSpire holds:

- **No long-lived credentials in the customer's account.** Access is
  via cross-account `sts:AssumeRole` only [`iam.tf` →
  `aws_iam_role.three_am_deployment`].
- **No ability to read or modify the CMK policy.** Only the customer's
  admin roles and the account root can manage the key [`kms.tf` →
  `data.aws_iam_policy_document.cmk`, statements 1 and 2]. AxelSpire's
  grant is data-plane only [statement 3].
- **No `organizations:*`, no broad untagged `s3:*` or `ec2:*`.** The
  full permission surface is the union of inline policies on
  `ThreeAM-Deployment`. Service wildcards (`ssm:*`, `logs:*`, `iam:*` on
  `3am-*` ARNs, `ec2:*` on resources tagged `Service=3am`, etc.) replace
  long action lists where tag or ARN scoping keeps blast radius narrow.
- **No ability to assume the role outside the AxelSpire CI account.** The
  trust policy names exactly one principal: the
  `GitHubActions-CustomerDeploy` role in the AxelSpire CI account
  [`iam.tf` → `data.aws_iam_policy_document.deployment_trust`]. The
  external ID is an additional condition the customer controls and can
  rotate at any time [`variables.tf` → `external_id_secret_arn`].
- **No user in the customer's Identity Center directory.** The
  `3AM-Platform-Admins` and `3AM-BreakGlass` groups, their members, and
  the `PlatformAdmin` / `BreakGlass` permission sets created by
  [`_scripts/customer-org-setup.sh`](../_scripts/customer-org-setup.sh)
  and
  [`_scripts/single-account-setup.sh`](../_scripts/single-account-setup.sh)
  are entirely customer-owned. They grant access only to the customer's
  own AWS account and are independent of the cross-account
  `ThreeAM-Deployment` role.

## 2. Trust policy walkthrough

The role has two trust statements, split by action because
`sts:RoleSessionName` and `sts:ExternalId` are not valid context keys
for `sts:TagSession` and would silently fail the condition check on
every `TagSession` call from a 3am-* session.

`AllowAxelspireCIAssumeRole` — `sts:AssumeRole` with up to three
conditions:

| Condition | Effect | Notes |
|---|---|---|
| `aws:PrincipalArn = arn:aws:iam::<CI-account>:role/<CI-role>` | Only that specific role can assume. | Hard-coded by `axelspire_ci_account_id` + `axelspire_ci_role_name` inputs. |
| `sts:RoleSessionName LIKE 3am-* OR tg-*` | Sessions must self-identify. | Visible in CloudTrail as `userIdentity.sessionContext.sessionIssuer.arn` + `requestParameters.roleSessionName`. |
| `sts:ExternalId = <secret value>` | (Optional) Re-asserts customer control. | Customer rotates the value in Secrets Manager; AxelSpire is given the new value out-of-band. Re-apply this module to roll. |

`AllowAxelspireCITagSession` — `sts:TagSession` with one optional
condition:

| Condition | Effect | Notes |
|---|---|---|
| `aws:RequestTag/LicenseValid = true` | (Optional) AxelSpire CI must attach a session tag declaring license validity. | Enforced at the AssumeRole call; tampering with the tag is visible in CloudTrail. |

## 3. Permission policy walkthrough

Three inline policies, all attached to the same role.

### `ThreeAM-Deployment-Permissions` [`iam.tf`]

- `lambda:*` scoped to `function:3am-*`.
- KMS data-plane on the customer CMK only (no `kms:PutKeyPolicy`, no
  `kms:ScheduleKeyDeletion`, no `kms:CreateGrant`).
- S3 on the state bucket only (object read/write/delete + list).
- DynamoDB on the lock table only (`GetItem`/`PutItem`/`DeleteItem`/
  `DescribeTable`).

### `ThreeAM-Deployment-Permissions-Ec2` [`iam-permissions-ec2.tf`]

- Read-only on VPC topology (Describe* on VPCs, subnets, SGs, …).
- Security-group write only when the SG is tagged `Service=3am`.
- `CreateSecurityGroup` only when the create request tags it
  `Service=3am`.

### `ThreeAM-Deployment-Permissions-Extra` [`iam-permissions-extra.tf`]

- SSM read/write on `/3am*` parameters (`/3am/bootstrap`, `/3am-infra/*`,
  `/3am-internal/*`, `/3am-core/*`, …). `DescribeParameters` on `Resource: "*"`.
- CloudWatch Logs on `/aws/lambda/3am-*` and `/3am/*` log groups only.
- API Gateway full CRUD on resources tagged `Service=3am`.
- Route 53: `route53:*` read; `route53:Change*` on hosted zones (infra APIGW/ACM validation records).
- ACM: list and request anywhere; describe/delete/tag on certificates
  tagged `Service=3am`.

### `ThreeAM-Deployment-Permissions-Apps` [`iam-permissions-apps.tf`]

- IAM read on AWS-managed policies (`iam:GetPolicy*` on `arn:aws:iam::aws:policy/*`).
- Lambda full access on all functions in the account (app stacks use `pki-*`, `authorizer-*`, …).
- IAM full access on customer `role/*` and `policy/*` (Lambda execution roles).

## 4. CMK policy walkthrough

Five statements [`kms.tf`]:

1. **Account root** — full `kms:*`. Standard "self" statement; required
   by AWS so the customer cannot lock themselves out.
2. **Customer admin roles** — full key management (rotate, disable,
   schedule deletion, tag, modify). Driven by `customer_admin_role_arns`.
3. **AxelSpire deployment role** — data-plane only. Cannot rotate,
   disable, delete, or change the key policy.
4. **Lambda service principal** — Encrypt/Decrypt/GenerateDataKey,
   conditioned on `kms:ViaService = lambda.<region>.amazonaws.com` and
   `kms:CallerAccount = <this account>`. Required to use the CMK as the
   environment-variable encryption key for 3AM Lambdas.
5. **S3 service principal** — same data-plane actions as Lambda, but
   `kms:ViaService = s3.<region>.amazonaws.com`. Required for SSE-KMS
   buckets (audit bucket, application data) without granting
   `kms:CreateGrant` on the deployment role.

## 5. Audit & detection

- All cross-account AssumeRole calls land in the customer's CloudTrail
  with `userIdentity.sessionContext.sessionIssuer.arn` = the AxelSpire
  CI role and `roleSessionName` starting with `3am-` or `tg-`.
- The state bucket has versioning + a TLS-only bucket policy
  [`state-backend.tf`]. Optional VPC endpoint restriction via
  `state_bucket_force_vpce`.
- The CMK has annual rotation enabled by default
  [`variables.tf` → `kms_key_rotation_enabled`].

## 6. Revocation

To end the engagement in minutes, the customer does any one of:

1. Detach the three inline policies from `ThreeAM-Deployment` (preserves
   the role for audit-trail purposes; removes all power).
2. Replace the trust policy with a deny-all (preserves policies for
   audit).
3. Delete the role entirely.
4. Revoke the CMK alias and disable the key. Downstream 3AM stacks lose
   the ability to decrypt their data; AxelSpire cannot re-enable.

## 7. Hand-off to AxelSpire

After a successful apply, share these values via the agreed secure
channel (signed email, ITSM ticket, internal portal):

- `customer_id`, `region`, `account_id`
- `deployment_role_arn`
- `customer_kms_key_arn`
- `state_bucket_name`, `state_lock_table_name`
- `bootstrap_version` (the module version applied)
- External ID value, if used (rotate after first AxelSpire deploy)

Convenience output: `output.handoff_values` bundles all of the above.

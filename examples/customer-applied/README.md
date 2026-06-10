# Example: customer-applied bootstrap

The customer's platform team runs this against their own AWS account.
AxelSpire never holds credentials during the apply; it only becomes a
trusted `Principal` on the `ThreeAM-Deployment` role once the apply
succeeds and the customer has shared the role ARN.

## Prerequisites

1. An AWS account that will host the 3AM workload, with the
   `3am-region-deny` / `3am-root-user-deny` SCPs and the
   `PlatformAdmin` / `BreakGlass` Identity Center setup already in place.
   Two CloudShell helpers can produce that end-state in one re-entrant
   pass:
   [`_scripts/customer-org-setup.sh`](../../_scripts/customer-org-setup.sh)
   (creates a dedicated child account in a `3AM` OU — recommended) or
   [`_scripts/single-account-setup.sh`](../../_scripts/single-account-setup.sh)
   (uses the current Org-management account as the workload account —
   small customers / POCs). See the
   [README → Run the setup (CloudShell)](../../README.md#run-the-setup-cloudshell)
   section.
2. Admin credentials for that account (e.g. an SSO role with
   `AdministratorAccess` or an equivalently-scoped custom role).
3. A Secrets Manager secret named `/3am/license/external-id` in the
   target account holding the external ID value. Pre-create it:
   ```
   aws secretsmanager create-secret \
     --name /3am/license/external-id \
     --secret-string "$(openssl rand -hex 32)"
   ```
4. The AxelSpire CI account ID (fixed: `033113129683`).
5. The AxelSpire-supplied **hand-off bundle** for this customer (alias ARN
   of the per-customer CI CMK + ARN of the shared CI artifacts bucket).
   These appear in the body of the merged AxelSpire `customer-onboard`
   PR.

## Apply

```
export AWS_PROFILE=customer-admin
tofu init
tofu apply \
  -var customer_id=acme-corp \
  -var region=eu-west-1 \
  -var axelspire_ci_account_id=033113129683 \
  -var 'customer_admin_role_arns=["arn:aws:iam::123456789012:role/PlatformAdmin"]' \
  -var axelspire_artifact_kms_key_arn=arn:aws:kms:eu-west-1:033113129683:alias/3am-ci/acme-corp \
  -var axelspire_artifact_s3_bucket_arn=arn:aws:s3:::3am-ci-artifacts-033113129683-eu-west-1
```

## Hand-off

Capture the `handoff_values` output and share with AxelSpire via the
agreed secure channel. The external ID itself is **not** in the
Terraform output; retrieve it from Secrets Manager and share separately:

```
aws secretsmanager get-secret-value \
  --secret-id /3am/license/external-id \
  --query SecretString --output text
```

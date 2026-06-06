# Example: customer-applied bootstrap

The customer's platform team runs this against their own AWS account.
AxelSpire never holds credentials during the apply; it only becomes a
trusted `Principal` on the `ThreeAM-Deployment` role once the apply
succeeds and the customer has shared the role ARN.

## Prerequisites

1. An AWS account in the customer's AWS Organization, dedicated to 3AM.
2. Admin credentials for that account (e.g. an SSO role with
   `AdministratorAccess` or an equivalently-scoped custom role).
3. A Secrets Manager secret named `/3am/license/external-id` in the
   target account holding the external ID value. Pre-create it:
   ```
   aws secretsmanager create-secret \
     --name /3am/license/external-id \
     --secret-string "$(openssl rand -hex 32)"
   ```
4. The AxelSpire CI account ID (provided by AxelSpire, e.g. `111122223333`).

## Apply

```
export AWS_PROFILE=customer-admin
tofu init
tofu apply \
  -var customer_id=acme-corp \
  -var region=eu-west-1 \
  -var axelspire_ci_account_id=111122223333 \
  -var 'customer_admin_role_arns=["arn:aws:iam::123456789012:role/PlatformAdmin"]'
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

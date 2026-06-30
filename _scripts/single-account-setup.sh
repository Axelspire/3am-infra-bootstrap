#!/usr/bin/env bash
# single-account-setup.sh — 3AM full bootstrap inside an existing single
# AWS account: Identity Center / SCPs (Phase 0) plus the cross-account
# IAM role, customer CMK, Terraform state backend and SSM parameters
# (Phase 5). Emits a single handoff.json blob describing everything
# AxelSpire needs to take over.
#
# Use this when the 3AM workload runs in the same AWS account as the Org
# root (e.g. a freshly-signed-up AWS account that is its own Organization
# management account — typical for small customers and POCs). The caller's
# current account is used both as the SCP-owning Org-management context
# AND as the workload target for IAM Identity Center assignments and the
# Phase 5 bootstrap resources. No new AWS account is created and no OU
# shuffle is performed.
#
# For the multi-account variant (creates a new child account in a 3AM OU
# and runs Phase 5 inside it), use customer-org-setup.sh instead.
#
# Idempotent: safe to re-run after a partial failure.

set -Eeuo pipefail

BOOTSTRAP_VERSION="0.2.24"
BOOTSTRAP_VARIANT="single-account"
SCRIPT_LAST_UPDATED="2026-06-30"
BOOTSTRAP_SCRIPT_NAME="single-account-setup.sh"
BOOTSTRAP_REPO="${BOOTSTRAP_REPO:-Axelspire/3am-infra-bootstrap}"
BOOTSTRAP_GIT_REF="${BOOTSTRAP_GIT_REF:-main}"
SKIP_SELF_UPDATE=false

_bootstrap_self_update_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_bootstrap_self_update_dir}/bootstrap-self-update.inc.sh" ]]; then
  # shellcheck source=bootstrap-self-update.inc.sh
  source "${_bootstrap_self_update_dir}/bootstrap-self-update.inc.sh"
elif command -v curl >/dev/null 2>&1; then
  _bootstrap_self_update_inc="$(mktemp)"
  if curl -fsSL --connect-timeout 10 --max-time 45 \
    "https://raw.githubusercontent.com/${BOOTSTRAP_REPO}/${BOOTSTRAP_GIT_REF}/_scripts/bootstrap-self-update.inc.sh" \
    -o "${_bootstrap_self_update_inc}" 2>/dev/null; then
    # shellcheck source=/dev/null
    source "${_bootstrap_self_update_inc}"
  fi
  rm -f "${_bootstrap_self_update_inc}"
fi
unset _bootstrap_self_update_dir _bootstrap_self_update_inc

# ---------------------------------------------------------------------------
# Defaults & globals
# ---------------------------------------------------------------------------
# Policy bodies are written to /tmp at runtime (see write_policy_files
# and phase5_write_policy_files), so the script remains a single-file
# curl-and-run.
REGION_POLICY_FILE="/tmp/3am-region-deny.json"
ROOT_POLICY_FILE="/tmp/3am-root-user-deny.json"
TRUST_POLICY_FILE="/tmp/3am-deployment-trust.json"
PERMS_POLICY_FILE="/tmp/3am-deployment-permissions.json"
PERMS_EC2_FILE="/tmp/3am-deployment-permissions-ec2.json"
PERMS_EXTRA_FILE="/tmp/3am-deployment-permissions-extra.json"
PERMS_ONBOARDING_FILE="/tmp/3am-deployment-permissions-onboarding.json"
PERMS_INFRA_FILE="/tmp/3am-deployment-permissions-infra.json"
PERMS_APPS_FILE="/tmp/3am-deployment-permissions-apps.json"
CMK_POLICY_FILE="/tmp/3am-customer-cmk-policy.json"
STATE_BUCKET_POLICY_FILE="/tmp/3am-state-bucket-policy.json"
DRIFT_TRUST_POLICY_FILE="/tmp/3am-drift-reader-trust.json"
DRIFT_STATE_POLICY_FILE="/tmp/3am-drift-reader-state.json"
DRIFT_WORKLOAD_POLICY_FILE="/tmp/3am-drift-reader-workload.json"

ALLOWED_REGIONS_CSV="eu-west-1,us-east-1"
PLATFORM_ADMINS_GROUP="3AM-Platform-Admins"
BREAKGLASS_GROUP="3AM-BreakGlass"
EXTERNAL_IDP=false
SKIP_SCPS=false
SKIP_BOOTSTRAP=false
SKIP_ORG=false
AUTO_APPROVE=false
QUIET=false
LOG_DIR="${HOME}"
COMMAND="apply"

# Phase 5 defaults (operator usually leaves these alone).
AXELSPIRE_CI_ACCOUNT_ID="033113129683"
AXELSPIRE_CI_REGION="eu-west-1"
AXELSPIRE_CI_ROLE_NAME="GitHubActions-CustomerDeploy"
AXELSPIRE_CI_DRIFT_ROLE_NAME="GitHubActions-DriftDetect"
AXELSPIRE_OPERATOR_ROLE_NAME="Operator-Admin"   # CI-account role allowed to assume ThreeAM-Deployment for local debugging
DEPLOYMENT_ROLE_NAME="ThreeAM-Deployment"
DRIFT_READER_ROLE_NAME="ThreeAM-DriftReader"
EXTERNAL_ID_SECRET_NAME="/3am/license/external-id"
REQUIRE_LICENSE_SESSION_TAG=true
KMS_MULTI_REGION=false
STATE_LOCK_TABLE_NAME="3am-state-lock"
CUSTOMER_CMK_ALIAS="alias/3am-customer-cmk"

# Per-customer inputs (no defaults — must be supplied on first apply).
CUSTOMER_NAME=""
CUSTOMER_ID=""
PLATFORM_ADMIN_USER=""
BREAKGLASS_USER=""

# Resolved at runtime.
INSTANCE_ARN=""
IDSTORE_ID=""
ROOT_ID=""
ACCOUNT_ID=""
PARTITION=""
EFFECTIVE_REGION=""
DEPLOYMENT_REGION=""
REGION_POLICY_ID=""
ROOT_POLICY_ID=""
PS_PLATFORM_ARN=""
PS_BREAKGLASS_ARN=""
PA_GROUP_ID=""
BG_GROUP_ID=""
PA_USER_ID=""
BG_USER_ID=""
PA_ROLE_ARN=""
BG_ROLE_ARN=""

# Phase 5 outputs.
DEPLOYMENT_ROLE_ARN=""
DRIFT_READER_ROLE_ARN=""
CUSTOMER_CMK_ARN=""
CUSTOMER_CMK_KEY_ID=""
EXTERNAL_ID_SECRET_ARN=""
STATE_BUCKET_NAME=""
AXELSPIRE_ARTIFACT_KMS_KEY_ARN=""
AXELSPIRE_ARTIFACT_S3_BUCKET_ARN=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
init_logging () {
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/3am-single-account-setup-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  trap 'echo; echo "FAILED at line ${LINENO} (exit $?). Log: ${LOG_FILE}" >&2' ERR
  log "log file: ${LOG_FILE}"
  local _arg _quoted=""
  for _arg in "${INVOCATION_ARGV[@]}"; do
    _quoted+=" $(printf '%q' "${_arg}")"
  done
  log "invoked as: $0${_quoted}"
}

log ()  { echo "[$(date -u +%H:%M:%SZ)] $*"; }
say ()  { ${QUIET} || echo "$*"; }
warn () { echo "WARN: $*" >&2; }
die ()  { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage () {
  cat <<'USAGE'
Usage: single-account-setup.sh [COMMAND] [OPTIONS]

Set up 3AM Identity Center, SCPs and the Phase 5 bootstrap resources
(ThreeAM-Deployment role, customer CMK, state backend, external-ID
secret, SSM parameters) inside the AWS account you are currently
signed into. Emits a single handoff.json blob for AxelSpire.

Commands:
  apply        Run / resume the full setup (default).
  preflight    Run only the preflight checks (no AWS writes).
  outputs      Re-resolve and print outputs as human-readable text.
  outputs-json Re-resolve and print outputs as JSON (for CI/CD ingestion).
  help         Show this help.

Required on first apply (subsequent runs reuse existing resources):
  --breakglass-user EMAIL       First member of the break-glass group.
                                Must be a deliberate choice; not
                                auto-derived. Ideally a different
                                identity from the platform admin. Not
                                required with --external-idp.

Auto-derived from the calling AWS account when omitted:
  --customer-name NAME          Customer display name. Default: the IAM
                                account alias if set, else "account-<ID>".
  --customer-id SLUG            Lowercase slug used in resource tags and
                                the AxelSpire CI key alias. Default: a
                                slug derived from --customer-name.
  --platform-admin-user EMAIL   First member of the platform-admin group
                                (UserName in Identity Center directory).
                                Default: Organization MasterAccountEmail.

Optional:
  --allowed-regions LIST        CSV, default: "eu-west-1,us-east-1".
                                Used to parameterise the region-deny SCP.
  --deployment-region REGION    Customer workload region: where the state
                                bucket, DynamoDB lock table, customer CMK
                                and external-ID secret live, and which
                                the --axelspire-artifact-kms-key-arn must
                                match. Default: the shell's AWS_REGION
                                (which also drives Identity Center calls).
                                Set this explicitly when the IAM Identity
                                Center home region differs from the
                                customer's deployment region (IDC is
                                one-per-org). Must be in --allowed-regions.
  --platform-admins-group NAME  Default: "3AM-Platform-Admins".
  --breakglass-group NAME       Default: "3AM-BreakGlass".
  --external-idp                Skip user/group creation; expect them to
                                come from an external IdP via SCIM.
  --skip-scps                   Do not create or attach the 3am-region-deny
                                / 3am-root-user-deny SCPs.
  --skip-bootstrap              Run Phase 0 (Identity Center / SCPs) only;
                                skip the Phase 5 bootstrap resources.
  --skip-org                    Skip Phase 0 and run Phase 5 only (useful
                                when re-running after a partial Phase 5
                                failure, or when Phase 0 was done out-of-band).

Phase 5 tuning (defaults are correct for the standard AxelSpire setup):
  --axelspire-ci-account-id ID  Default: 033113129683.
  --axelspire-ci-region REGION  Default: eu-west-1. Documentation hint
                                only; the AxelSpire CI artifacts bucket
                                lives in the CI account and is region-
                                less in its ARN.
  --axelspire-ci-role-name NAME Default: GitHubActions-CustomerDeploy.
  --axelspire-artifact-kms-key-arn ARN
                                Key-ID ARN of the customer-region MRK
                                replica of the per-customer AxelSpire CI
                                CMK. Required. Must be of the form
                                arn:<partition>:kms:<region>:<ci-acct>:key/<uuid>
                                (alias ARNs are rejected: IAM Resource
                                matching does not authorize via aliases),
                                and the region must equal the customer's
                                deployment region (DynamoDB SSE-KMS
                                requires a same-region key). Obtain by
                                running `terragrunt output kms_key_arn`
                                on the customer-ci-key-replica leaf for
                                this customer/region pair.
  --axelspire-artifact-s3-bucket-arn ARN
                                Override the deterministic
                                arn:aws:s3:::3am-ci-artifacts-<ci-acct>
                                bucket ARN (CI account is single-region;
                                no region suffix). Optional;
                                documentation-only (no API calls in this
                                script reference it).
  --external-id-secret-name N   Default: /3am/license/external-id.
                                Auto-created (32-byte hex) if missing.
  --no-license-session-tag      Drop the aws:RequestTag/LicenseValid
                                condition from the role trust policy.
  --kms-multi-region            Create the customer CMK as multi-region.

  --auto-approve                Skip interactive confirmation.
  --log-dir PATH                Default: $HOME (CloudShell-persistent).
  --quiet                       Reduce console noise (file log is full).
  --skip-self-update            Do not check GitHub for a newer script
                                (also: SKIP_SELF_UPDATE=1 or
                                BOOTSTRAP_SELF_UPDATE_REEXEC=1).

Outputs commands take no per-customer flags; they re-resolve every value
from AWS using the group / permission-set / role names.

Examples:
  # Minimal: customer-name and platform-admin auto-derived from AWS
  ./single-account-setup.sh apply \
    --breakglass-user bob@acme.example.com

  # Explicit override of every input
  ./single-account-setup.sh apply \
    --customer-name "Acme Corp" \
    --customer-id acme-corp \
    --platform-admin-user alice@acme.example.com \
    --breakglass-user bob@acme.example.com

  # CI ingestion later
  ./single-account-setup.sh outputs-json > single-account-setup.json
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args () {
  case "${1:-apply}" in
    apply|preflight|outputs|outputs-json|help|-h|--help)
      COMMAND="${1:-apply}"; shift || true ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --customer-name)             CUSTOMER_NAME="$2"; shift 2 ;;
      --customer-id)               CUSTOMER_ID="$2"; shift 2 ;;
      --allowed-regions)           ALLOWED_REGIONS_CSV="$2"; shift 2 ;;
      --deployment-region)         DEPLOYMENT_REGION="$2"; shift 2 ;;
      --platform-admin-user)       PLATFORM_ADMIN_USER="$2"; shift 2 ;;
      --breakglass-user)           BREAKGLASS_USER="$2"; shift 2 ;;
      --platform-admins-group)     PLATFORM_ADMINS_GROUP="$2"; shift 2 ;;
      --breakglass-group)          BREAKGLASS_GROUP="$2"; shift 2 ;;
      --external-idp)              EXTERNAL_IDP=true; shift ;;
      --skip-scps)                 SKIP_SCPS=true; shift ;;
      --skip-bootstrap)            SKIP_BOOTSTRAP=true; shift ;;
      --skip-org)                  SKIP_ORG=true; shift ;;
      --axelspire-ci-account-id)   AXELSPIRE_CI_ACCOUNT_ID="$2"; shift 2 ;;
      --axelspire-ci-region)       AXELSPIRE_CI_REGION="$2"; shift 2 ;;
      --axelspire-ci-role-name)    AXELSPIRE_CI_ROLE_NAME="$2"; shift 2 ;;
      --axelspire-artifact-kms-key-arn)    AXELSPIRE_ARTIFACT_KMS_KEY_ARN="$2"; shift 2 ;;
      --axelspire-artifact-s3-bucket-arn)  AXELSPIRE_ARTIFACT_S3_BUCKET_ARN="$2"; shift 2 ;;
      --external-id-secret-name)   EXTERNAL_ID_SECRET_NAME="$2"; shift 2 ;;
      --no-license-session-tag)    REQUIRE_LICENSE_SESSION_TAG=false; shift ;;
      --kms-multi-region)          KMS_MULTI_REGION=true; shift ;;
      --auto-approve)              AUTO_APPROVE=true; shift ;;
      --log-dir)                   LOG_DIR="$2"; shift 2 ;;
      --quiet)                     QUIET=true; shift ;;
      --skip-self-update)          SKIP_SELF_UPDATE=true; shift ;;
      -h|--help)                   usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
}


# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight () {
  log "preflight: caller identity"
  aws sts get-caller-identity --output table
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "None" ] || die "could not resolve caller account ID"
  PARTITION=$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)
  [ -n "$PARTITION" ] || PARTITION="aws"
  log "preflight: caller account = ${ACCOUNT_ID} (partition ${PARTITION})"

  EFFECTIVE_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
  [ -n "$EFFECTIVE_REGION" ] || EFFECTIVE_REGION="<unset>"
  log "preflight: effective region = ${EFFECTIVE_REGION} (Identity Center / Organizations APIs target this region)"

  # DEPLOYMENT_REGION drives the customer workload: state bucket, lock
  # table, customer CMK, external-ID secret, kms:ViaService in the CMK
  # policy, and the region match for --axelspire-artifact-kms-key-arn.
  # Defaults to EFFECTIVE_REGION; set --deployment-region explicitly when
  # the IDC home region differs from where the customer should deploy.
  if [ -z "${DEPLOYMENT_REGION}" ]; then
    DEPLOYMENT_REGION="${EFFECTIVE_REGION}"
  fi
  [ "${DEPLOYMENT_REGION}" != "<unset>" ] && [ -n "${DEPLOYMENT_REGION}" ] \
    || die "deployment region is unset: pass --deployment-region or export AWS_REGION"
  log "preflight: deployment region = ${DEPLOYMENT_REGION} (state bucket, lock table, customer CMK live here)"
  case ",${ALLOWED_REGIONS_CSV}," in
    *,"${DEPLOYMENT_REGION}",*) : ;;
    *) die "deployment region '${DEPLOYMENT_REGION}' is not in --allowed-regions '${ALLOWED_REGIONS_CSV}' (the 3am-region-deny SCP would block it)" ;;
  esac

  if ${SKIP_ORG}; then
    log "preflight: --skip-org set, skipping Org / Identity Center checks"
    return
  fi

  log "preflight: organization feature set"
  local fs mgmt
  fs=$(aws organizations describe-organization \
        --query 'Organization.FeatureSet' --output text 2>/dev/null) || \
    die "not logged into an Org-management account (or not part of an Organization)"
  [ "$fs" = "ALL" ] || die "Organization is in '${fs}' mode; ALL features required for SCPs"

  mgmt=$(aws organizations describe-organization \
          --query 'Organization.MasterAccountId' --output text)
  [ "$mgmt" = "$ACCOUNT_ID" ] || die "caller account ${ACCOUNT_ID} is not the Org management account (${mgmt}). single-account-setup.sh expects to run in the management account itself; use customer-org-setup.sh for the multi-account variant."

  ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
  [ "$ROOT_ID" != "None" ] || die "could not resolve Organization root ID"
  log "preflight: org root = ${ROOT_ID}"

  log "preflight: Identity Center"
  INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text 2>/dev/null || echo None)
  IDSTORE_ID=$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text 2>/dev/null || echo None)
  if [ "$INSTANCE_ARN" = "None" ] || [ -z "$INSTANCE_ARN" ]; then
    die "IAM Identity Center is not enabled in region '${EFFECTIVE_REGION}'. Enable it in the console (one-time, Org-mgmt account) — or if it is already enabled in a different region, re-run with: AWS_REGION=<that-region> $0 ${COMMAND}"
  fi
  log "preflight: Identity Center instance = ${INSTANCE_ARN}"
  log "preflight: identity store = ${IDSTORE_ID}"

  if ! ${SKIP_SCPS}; then
    log "preflight: ensure SCP and TAG policy types enabled on root (idempotent)"
    aws organizations enable-policy-type --root-id "${ROOT_ID}" \
      --policy-type SERVICE_CONTROL_POLICY >/dev/null 2>&1 || true
    aws organizations enable-policy-type --root-id "${ROOT_ID}" \
      --policy-type TAG_POLICY >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# Policy file generation (embedded; rewritten on every apply).
# ---------------------------------------------------------------------------
write_policy_files () {
  local regions_json
  regions_json=$(printf '"%s"' "${ALLOWED_REGIONS_CSV//,/\",\"}")
  log "writing ${REGION_POLICY_FILE} (allowed regions: ${ALLOWED_REGIONS_CSV})"
  cat > "${REGION_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAllOutsideAllowedRegions",
      "Effect": "Deny",
      "NotAction": [
        "iam:*", "organizations:*", "route53:*", "cloudfront:*",
        "waf:*", "waf-regional:*", "wafv2:*", "support:*", "sts:*",
        "kms:*", "s3:GetAccountPublicAccessBlock", "s3:ListAllMyBuckets",
        "health:*", "tag:*", "globalaccelerator:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": { "aws:RequestedRegion": [${regions_json}] }
      }
    }
  ]
}
EOF
  log "writing ${ROOT_POLICY_FILE}"
  cat > "${ROOT_POLICY_FILE}" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRootUser",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringLike": { "aws:PrincipalArn": "arn:aws:iam::*:root" }
      }
    },
    {
      "Sid": "DenyLeavingOrganization",
      "Effect": "Deny",
      "Action": "organizations:LeaveOrganization",
      "Resource": "*"
    }
  ]
}
EOF
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool < "${REGION_POLICY_FILE}" > /dev/null || die "generated ${REGION_POLICY_FILE} is not valid JSON"
    python3 -m json.tool < "${ROOT_POLICY_FILE}"   > /dev/null || die "generated ${ROOT_POLICY_FILE} is not valid JSON"
  fi
}


# ---------------------------------------------------------------------------
# Idempotent helpers — each prints the resolved ID/ARN on stdout; chatter
# goes to stderr via log/warn.
# ---------------------------------------------------------------------------
get_or_create_scp () {
  local name=$1 file=$2 id
  [ -f "$file" ] || die "policy file not found: ${file}"
  id=$(aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
        --query "Policies[?Name==\`${name}\`].Id | [0]" --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    log "creating SCP '${name}' from ${file}" >&2
    id=$(aws organizations create-policy \
          --name "${name}" --type SERVICE_CONTROL_POLICY \
          --description "managed by single-account-setup.sh" \
          --content "file://${file}" \
          --query 'Policy.PolicySummary.Id' --output text)
  else
    log "updating SCP '${name}' (${id}) body from ${file}" >&2
    aws organizations update-policy --policy-id "${id}" \
      --content "file://${file}" >/dev/null
  fi
  echo "$id"
}

attach_policy_if_missing () {
  local policy=$1 target=$2 hit
  hit=$(aws organizations list-policies-for-target \
        --target-id "${target}" --filter SERVICE_CONTROL_POLICY \
        --query "Policies[?Id==\`${policy}\`].Id | [0]" --output text)
  if [ "$hit" = "None" ] || [ -z "$hit" ]; then
    log "attaching ${policy} -> ${target}" >&2
    aws organizations attach-policy --policy-id "${policy}" --target-id "${target}"
  else
    log "${policy} already attached to ${target}" >&2
  fi
}

get_or_create_permission_set () {
  local name=$1 duration=$2 arn description
  description="3AM ${name} (managed by single-account-setup.sh)"
  for arn in $(aws sso-admin list-permission-sets \
                --instance-arn "${INSTANCE_ARN}" \
                --query 'PermissionSets[]' --output text); do
    local n
    n=$(aws sso-admin describe-permission-set \
          --instance-arn "${INSTANCE_ARN}" --permission-set-arn "$arn" \
          --query 'PermissionSet.Name' --output text)
    if [ "$n" = "$name" ]; then
      log "reusing permission set '${name}' = ${arn}" >&2
      echo "$arn"; return
    fi
  done
  log "creating permission set '${name}' (session ${duration})" >&2
  arn=$(aws sso-admin create-permission-set \
          --instance-arn "${INSTANCE_ARN}" \
          --name "${name}" --session-duration "${duration}" \
          --description "${description}" \
          --query 'PermissionSet.PermissionSetArn' --output text)
  echo "$arn"
}

attach_managed_policy_if_missing () {
  local ps_arn=$1 managed=$2 hit
  hit=$(aws sso-admin list-managed-policies-in-permission-set \
        --instance-arn "${INSTANCE_ARN}" --permission-set-arn "${ps_arn}" \
        --query "AttachedManagedPolicies[?Arn==\`${managed}\`].Arn | [0]" \
        --output text)
  if [ "$hit" = "None" ] || [ -z "$hit" ]; then
    log "attaching ${managed} -> ${ps_arn}" >&2
    aws sso-admin attach-managed-policy-to-permission-set \
      --instance-arn "${INSTANCE_ARN}" --permission-set-arn "${ps_arn}" \
      --managed-policy-arn "${managed}"
  else
    log "${managed} already attached to permission set" >&2
  fi
}

get_or_create_group () {
  local name=$1 id
  id=$(aws identitystore list-groups \
        --identity-store-id "${IDSTORE_ID}" \
        --filters AttributePath=DisplayName,AttributeValue="${name}" \
        --query 'Groups[0].GroupId' --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    log "creating group '${name}'" >&2
    id=$(aws identitystore create-group \
          --identity-store-id "${IDSTORE_ID}" \
          --display-name "${name}" \
          --description "3AM (managed by single-account-setup.sh)" \
          --query 'GroupId' --output text)
  else
    log "reusing group '${name}' = ${id}" >&2
  fi
  echo "$id"
}

lookup_group_required () {
  local name=$1 id
  id=$(aws identitystore list-groups \
        --identity-store-id "${IDSTORE_ID}" \
        --filters AttributePath=DisplayName,AttributeValue="${name}" \
        --query 'Groups[0].GroupId' --output text)
  [ "$id" != "None" ] && [ -n "$id" ] || \
    die "group '${name}' not found in identity store ${IDSTORE_ID} (external IdP: provision and wait for SCIM sync)"
  echo "$id"
}

get_or_create_user () {
  local username=$1 id given family
  id=$(aws identitystore list-users \
        --identity-store-id "${IDSTORE_ID}" \
        --filters AttributePath=UserName,AttributeValue="${username}" \
        --query 'Users[0].UserId' --output text)
  if [ "$id" != "None" ] && [ -n "$id" ]; then
    log "reusing user '${username}' = ${id}" >&2
    echo "$id"; return
  fi
  log "creating user '${username}'" >&2
  local local_part="${username%@*}"
  given="${local_part%%.*}"
  family="${local_part#*.}"; [ "$family" = "$local_part" ] && family="User"
  id=$(aws identitystore create-user \
        --identity-store-id "${IDSTORE_ID}" \
        --user-name "${username}" \
        --name "GivenName=${given},FamilyName=${family}" \
        --display-name "${given} ${family}" \
        --emails "Value=${username},Type=Work,Primary=true" \
        --query 'UserId' --output text)
  echo "$id"
}

ensure_group_membership () {
  local group=$1 user=$2 hit
  hit=$(aws identitystore list-group-memberships-for-member \
        --identity-store-id "${IDSTORE_ID}" \
        --member-id "UserId=${user}" \
        --query "GroupMemberships[?GroupId==\`${group}\`].MembershipId | [0]" \
        --output text)
  if [ "$hit" = "None" ] || [ -z "$hit" ]; then
    log "adding user ${user} to group ${group}" >&2
    aws identitystore create-group-membership \
      --identity-store-id "${IDSTORE_ID}" \
      --group-id "${group}" --member-id "UserId=${user}" >/dev/null
  else
    log "user ${user} already in group ${group}" >&2
  fi
}


ensure_account_assignment () {
  local account=$1 ps_arn=$2 ptype=$3 pid=$4 hit req_id state
  hit=$(aws sso-admin list-account-assignments \
        --instance-arn "${INSTANCE_ARN}" \
        --account-id "${account}" --permission-set-arn "${ps_arn}" \
        --query "AccountAssignments[?PrincipalType==\`${ptype}\` && PrincipalId==\`${pid}\`].PrincipalId | [0]" \
        --output text)
  if [ "$hit" != "None" ] && [ -n "$hit" ]; then
    log "assignment already exists: ${ps_arn} -> ${ptype}/${pid} on ${account}" >&2
    return
  fi
  log "creating assignment: ${ps_arn} -> ${ptype}/${pid} on ${account}" >&2
  req_id=$(aws sso-admin create-account-assignment \
            --instance-arn "${INSTANCE_ARN}" \
            --target-id "${account}" --target-type AWS_ACCOUNT \
            --permission-set-arn "${ps_arn}" \
            --principal-id "${pid}" --principal-type "${ptype}" \
            --query 'AccountAssignmentCreationStatus.RequestId' --output text)
  local i=0
  while : ; do
    state=$(aws sso-admin describe-account-assignment-creation-status \
              --instance-arn "${INSTANCE_ARN}" \
              --account-assignment-creation-request-id "${req_id}" \
              --query 'AccountAssignmentCreationStatus.Status' --output text)
    case "$state" in
      SUCCEEDED) return ;;
      FAILED)
        local reason
        reason=$(aws sso-admin describe-account-assignment-creation-status \
                  --instance-arn "${INSTANCE_ARN}" \
                  --account-assignment-creation-request-id "${req_id}" \
                  --query 'AccountAssignmentCreationStatus.FailureReason' --output text)
        die "assignment failed: ${reason}"
        ;;
    esac
    i=$((i+1)); sleep 5
    [ $i -gt 60 ] && die "assignment did not converge after 5 min"
  done
}

# AWSReservedSSO_<PermissionSet>_<hash> role only exists once the
# assignment is SUCCEEDED. Because we are already in the target account
# (it is the caller), we can list roles directly without any AssumeRole.
resolve_reserved_sso_role_arn () {
  local ps_name=$1 role_arn
  role_arn=$(aws iam list-roles \
              --path-prefix /aws-reserved/sso.amazonaws.com/ \
              --query "Roles[?starts_with(RoleName, \`AWSReservedSSO_${ps_name}_\`)].Arn | [0]" \
              --output text 2>/dev/null || echo None)
  [ "$role_arn" = "None" ] && role_arn=""
  echo "$role_arn"
}

# Fill in --customer-name, --customer-id and --platform-admin-user from
# AWS when the operator did not supply them. --breakglass-user is never
# auto-derived: the break-glass identity must be a deliberate choice,
# ideally distinct from the platform-admin identity. Called after
# preflight so ACCOUNT_ID is already resolved.
resolve_apply_defaults () {
  local master_email alias
  if [ -z "$CUSTOMER_NAME" ]; then
    alias=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo None)
    if [ "$alias" != "None" ] && [ -n "$alias" ]; then
      CUSTOMER_NAME="$alias"
      log "auto-resolved --customer-name from IAM account alias: ${CUSTOMER_NAME}"
    else
      CUSTOMER_NAME="account-${ACCOUNT_ID}"
      log "no IAM account alias set; defaulting --customer-name to: ${CUSTOMER_NAME}"
    fi
  fi
  if [ -z "$CUSTOMER_ID" ]; then
    CUSTOMER_ID=$(printf '%s' "${CUSTOMER_NAME}" \
                    | tr '[:upper:]' '[:lower:]' \
                    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    [ -n "$CUSTOMER_ID" ] || CUSTOMER_ID="account-${ACCOUNT_ID}"
    log "auto-derived --customer-id from --customer-name: ${CUSTOMER_ID}"
  fi
  echo "${CUSTOMER_ID}" | grep -qE '^[a-z0-9-]+$' || die "--customer-id '${CUSTOMER_ID}' must be lowercase alphanumeric with hyphens only"
  if ${SKIP_ORG}; then return; fi
  if ! ${EXTERNAL_IDP} && [ -z "$PLATFORM_ADMIN_USER" ]; then
    master_email=$(aws organizations describe-organization \
                    --query 'Organization.MasterAccountEmail' \
                    --output text 2>/dev/null || echo "")
    [ -n "$master_email" ] || die "could not auto-resolve --platform-admin-user from Organization.MasterAccountEmail; pass it explicitly"
    PLATFORM_ADMIN_USER="$master_email"
    log "auto-resolved --platform-admin-user from Organization.MasterAccountEmail: ${PLATFORM_ADMIN_USER}"
  fi
  if ! ${EXTERNAL_IDP} && [ "$PLATFORM_ADMIN_USER" = "$BREAKGLASS_USER" ]; then
    log "WARNING: --platform-admin-user and --breakglass-user are the same identity (${PLATFORM_ADMIN_USER}). For production, use a separate break-glass identity."
  fi
}

# Derive the AxelSpire-side ARNs. The S3 bucket ARN follows a
# deterministic naming convention. The KMS value must be the customer-
# region MRK replica's key-ID ARN: alias ARNs do not authorize IAM
# Resource matching, and DynamoDB CreateTable requires a same-region
# customer-managed key.
phase5_validate_axelspire_kms_arn () {
  # Strict validation runs only on apply: outputs / outputs-json paths
  # may recover the ARN from SSM (see resolve_outputs), so an empty
  # value at this point is not fatal.
  [ "${COMMAND}" = "apply" ] || return 0
  [ -n "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" ] \
    || die "--axelspire-artifact-kms-key-arn is required (key-ID ARN of the customer-region MRK replica; see --help)"
  # MRK key IDs are 'mrk-<32 hex chars>'; single-region CMK key IDs are
  # UUIDs. Both terminate the ARN: nothing after the key id.
  echo "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" \
    | grep -qE "^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/(mrk-)?[0-9a-f-]+$" \
    || die "--axelspire-artifact-kms-key-arn must be a key-ID ARN of the form arn:<partition>:kms:<region>:<account>:key/<key-id> (MRK key IDs are 'mrk-<32 hex>'); alias ARNs and bare key IDs are not accepted. Got: ${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
  local key_region
  key_region=$(echo "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" | awk -F: '{print $4}')
  [ "${key_region}" = "${DEPLOYMENT_REGION}" ] \
    || die "--axelspire-artifact-kms-key-arn region '${key_region}' must equal the customer deployment region '${DEPLOYMENT_REGION}' (DynamoDB SSE-KMS requires a same-region key). Pass the customer-region MRK replica's key-ID ARN, or set --deployment-region to match the ARN."
}

phase5_compute_axelspire_arns () {
  phase5_validate_axelspire_kms_arn
  if [ -z "${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}" ]; then
    AXELSPIRE_ARTIFACT_S3_BUCKET_ARN="arn:${PARTITION}:s3:::3am-ci-artifacts-${AXELSPIRE_CI_ACCOUNT_ID}"
  fi
}

# ---------------------------------------------------------------------------
# Phase 5 — policy file generation (rewritten on every apply).
# ---------------------------------------------------------------------------
# SYNC: keep Phase 5 helpers through phase5_put_ssm_params identical in
# customer-org-setup.sh (except ManagedBy tag strings and org-only wrappers).
# Run _scripts/tests/test_phase5_bootstrap_parity.sh after edits.
# Mirrors deploy/iam.tf, deploy/iam-permissions-ec2.tf,
# deploy/iam-permissions-extra.tf, deploy/kms.tf and deploy/state-backend.tf.
# Files are validated with python3 -m json.tool after generation.
phase5_assert_inline_policy_sizes () {
  local max_per=10240 max_combined=10240 total=0 f bytes
  for f in "${PERMS_POLICY_FILE}" "${PERMS_EC2_FILE}" "${PERMS_EXTRA_FILE}" \
           "${PERMS_ONBOARDING_FILE}" "${PERMS_INFRA_FILE}" "${PERMS_APPS_FILE}"; do
    bytes=$(wc -c < "${f}" | tr -d ' ')
    if [ "${bytes}" -gt "${max_per}" ]; then
      die "inline policy ${f} is ${bytes} bytes (AWS per-policy limit ${max_per}) — split or shorten statements"
    fi
    total=$((total + bytes))
  done
  if [ "${total}" -gt "${max_combined}" ]; then
    die "combined ThreeAM-Deployment inline policies are ${total} bytes (AWS role limit ${max_combined}) — shorten or move to managed policies"
  fi
}

phase5_write_policy_files () {
  local external_id="${1:-}" admin_arns_json="${2:-[]}"
  # Trust policy is split into two statements. sts:RoleSessionName and
  # sts:ExternalId are not valid context keys for sts:TagSession, so a
  # single combined statement would fail the condition check on every
  # TagSession call from a 3am-* session. The AssumeRole statement
  # carries the session-name / external-id gates; the TagSession
  # statement carries only the aws:RequestTag/LicenseValid gate.
  log "writing ${TRUST_POLICY_FILE}"
  if command -v jq >/dev/null 2>&1; then
    local assume_conds='{"StringLike":{"sts:RoleSessionName":["3am-*","tg-*"]}}'
    [ -n "${external_id}" ] && assume_conds=$(echo "${assume_conds}" | jq --arg eid "${external_id}" \
                                          '. + {StringEquals: {"sts:ExternalId": $eid}}')
    local tag_conds='{}'
    if ${REQUIRE_LICENSE_SESSION_TAG}; then
      tag_conds='{"StringEquals":{"aws:RequestTag/LicenseValid":"true"}}'
    fi
    jq -n \
      --arg principal "arn:${PARTITION}:iam::${AXELSPIRE_CI_ACCOUNT_ID}:role/${AXELSPIRE_CI_ROLE_NAME}" \
      --arg op_principal "arn:${PARTITION}:iam::${AXELSPIRE_CI_ACCOUNT_ID}:role/${AXELSPIRE_OPERATOR_ROLE_NAME}" \
      --argjson assume_conds "${assume_conds}" \
      --argjson tag_conds "${tag_conds}" \
      '{
        Version: "2012-10-17",
        Statement: [
          {
            Sid: "AllowAxelspireCIAssumeRole",
            Effect: "Allow",
            Principal: { AWS: $principal },
            Action: "sts:AssumeRole",
            Condition: $assume_conds
          },
          ({
            Sid: "AllowAxelspireCITagSession",
            Effect: "Allow",
            Principal: { AWS: $principal },
            Action: "sts:TagSession"
          } + (if ($tag_conds | length) > 0 then {Condition: $tag_conds} else {} end)),
          {
            Sid: "AllowAxelspireOperatorAssumeRole",
            Effect: "Allow",
            Principal: { AWS: $op_principal },
            Action: "sts:AssumeRole",
            Condition: $assume_conds
          }
        ]
      }' > "${TRUST_POLICY_FILE}"
  else
    local assume_cond_json='{ "StringLike": { "sts:RoleSessionName": ["3am-*","tg-*"] } }'
    if [ -n "${external_id}" ]; then
      assume_cond_json="{ \"StringLike\": { \"sts:RoleSessionName\": [\"3am-*\",\"tg-*\"] }, \"StringEquals\": { \"sts:ExternalId\": \"${external_id}\" } }"
    fi
    local tag_stmt_tail=''
    if ${REQUIRE_LICENSE_SESSION_TAG}; then
      tag_stmt_tail=',
    "Condition": { "StringEquals": { "aws:RequestTag/LicenseValid": "true" } }'
    fi
    cat > "${TRUST_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAxelspireCIAssumeRole",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:${PARTITION}:iam::${AXELSPIRE_CI_ACCOUNT_ID}:role/${AXELSPIRE_CI_ROLE_NAME}" },
      "Action": "sts:AssumeRole",
      "Condition": ${assume_cond_json}
    },
    {
      "Sid": "AllowAxelspireCITagSession",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:${PARTITION}:iam::${AXELSPIRE_CI_ACCOUNT_ID}:role/${AXELSPIRE_CI_ROLE_NAME}" },
      "Action": "sts:TagSession"${tag_stmt_tail}
    },
    {
      "Sid": "AllowAxelspireOperatorAssumeRole",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:${PARTITION}:iam::${AXELSPIRE_CI_ACCOUNT_ID}:role/${AXELSPIRE_OPERATOR_ROLE_NAME}" },
      "Action": "sts:AssumeRole",
      "Condition": ${assume_cond_json}
    }
  ]
}
EOF
  fi

  log "writing ${PERMS_POLICY_FILE}"
  cat > "${PERMS_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "LambdaOn3amFunctions", "Effect": "Allow",
      "Action": ["lambda:*"],
      "Resource": ["arn:${PARTITION}:lambda:*:${ACCOUNT_ID}:function:3am-*"] },
    { "Sid": "KmsDataPlaneOnCustomerCmk", "Effect": "Allow",
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                 "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext","kms:DescribeKey"],
      "Resource": ["${CUSTOMER_CMK_ARN}"] },
    { "Sid": "KmsDataPlaneOnAxelspireArtifactCmk", "Effect": "Allow",
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                 "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext","kms:DescribeKey"],
      "Resource": ["${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"] },
    { "Sid": "S3OnStateBucket", "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:DeleteObject",
                 "s3:ListBucket","s3:ListBucketVersions","s3:GetBucketVersioning",
                 "s3:GetEncryptionConfiguration","s3:GetBucketLocation"],
      "Resource": ["arn:${PARTITION}:s3:::${STATE_BUCKET_NAME}",
                   "arn:${PARTITION}:s3:::${STATE_BUCKET_NAME}/*"] },
    { "Sid": "S3ReadOnAxelspireArtifactBucket", "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion","s3:ListBucket","s3:GetBucketLocation"],
      "Resource": ["${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}",
                   "${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}/*"] },
    { "Sid": "DynamoDBOnStateLockTable", "Effect": "Allow",
      "Action": ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:DeleteItem","dynamodb:DescribeTable"],
      "Resource": ["arn:${PARTITION}:dynamodb:*:${ACCOUNT_ID}:table/${STATE_LOCK_TABLE_NAME}"] }
  ]
}
EOF

  log "writing ${PERMS_EC2_FILE}"
  cat > "${PERMS_EC2_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "Ec2VpcRead", "Effect": "Allow",
      "Action": ["ec2:Describe*","ec2:GetManagedPrefixListEntries"],
      "Resource": ["*"] },
    { "Sid": "Ec2SecurityGroupWriteOnTagged", "Effect": "Allow",
      "Action": ["ec2:AuthorizeSecurityGroupIngress","ec2:AuthorizeSecurityGroupEgress",
                 "ec2:RevokeSecurityGroupIngress","ec2:RevokeSecurityGroupEgress",
                 "ec2:CreateTags","ec2:DeleteTags"],
      "Resource": ["arn:${PARTITION}:ec2:*:${ACCOUNT_ID}:security-group/*"],
      "Condition": { "StringEquals": { "aws:ResourceTag/Service": "3am" } } },
    { "Sid": "Ec2SecurityGroupCreate", "Effect": "Allow",
      "Action": ["ec2:CreateSecurityGroup"], "Resource": ["*"],
      "Condition": { "StringEquals": { "aws:RequestTag/Service": "3am" } } }
  ]
}
EOF

  log "writing ${PERMS_EXTRA_FILE}"
  cat > "${PERMS_EXTRA_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["ssm:*"],
      "Resource": ["arn:${PARTITION}:ssm:*:${ACCOUNT_ID}:parameter/3am*"] },
    { "Effect": "Allow", "Action": ["ssm:DescribeParameters"], "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["logs:*"], "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["apigateway:*"],
      "Resource": ["arn:${PARTITION}:apigateway:*::/*"] },
    { "Effect": "Allow", "Action": ["route53:*"], "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["acm:*"], "Resource": ["*"] },
    { "Sid": "CloudWatchCore", "Effect": "Allow",
      "Action": ["cloudwatch:*"], "Resource": ["*"] },
    { "Sid": "CloudTrailCore", "Effect": "Allow",
      "Action": ["cloudtrail:*"], "Resource": ["*"] },
    { "Sid": "LambdaEventSourceMappingsOn3amFunctions", "Effect": "Allow",
      "Action": ["lambda:CreateEventSourceMapping","lambda:UpdateEventSourceMapping",
                 "lambda:DeleteEventSourceMapping","lambda:GetEventSourceMapping",
                 "lambda:ListEventSourceMappings"],
      "Resource": ["*"],
      "Condition": { "ArnLike": {
        "lambda:FunctionArn": "arn:${PARTITION}:lambda:*:${ACCOUNT_ID}:function:3am-*" } } },
    { "Sid": "LambdaEventSourceMappingTagging", "Effect": "Allow",
      "Action": ["lambda:TagResource","lambda:UntagResource","lambda:ListTags"],
      "Resource": ["arn:${PARTITION}:lambda:*:${ACCOUNT_ID}:event-source-mapping:*"] }
  ]
}
EOF

  log "writing ${PERMS_ONBOARDING_FILE}"
  cat > "${PERMS_ONBOARDING_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:*"],
      "Resource": [
        "arn:${PARTITION}:s3:::3am-audit-${ACCOUNT_ID}-${DEPLOYMENT_REGION}",
        "arn:${PARTITION}:s3:::3am-audit-${ACCOUNT_ID}-${DEPLOYMENT_REGION}/*"
      ] },
    { "Effect": "Allow", "Action": ["route53:*"], "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["ssm:DescribeParameters"], "Resource": ["*"] },
    { "Effect": "Allow",
      "Action": ["ssm:PutParameter","ssm:DeleteParameter","ssm:DeleteParameters",
                 "ssm:AddTagsToResource","ssm:RemoveTagsFromResource","ssm:ListTagsForResource",
                 "ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath"],
      "Resource": ["arn:${PARTITION}:ssm:*:${ACCOUNT_ID}:parameter/3am*"] }
  ]
}
EOF

  log "writing ${PERMS_INFRA_FILE}"
  cat > "${PERMS_INFRA_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "Ec2InfraVpc", "Effect": "Allow",
      "Action": ["ec2:*"],
      "Resource": ["*"] },
    { "Sid": "IamManage3amScopedPoliciesAndRoles", "Effect": "Allow",
      "Action": ["iam:*"],
      "Resource": ["arn:${PARTITION}:iam::${ACCOUNT_ID}:policy/3am-*",
                   "arn:${PARTITION}:iam::${ACCOUNT_ID}:role/3am-*"] },
    { "Sid": "EventsListRules", "Effect": "Allow",
      "Action": ["events:ListRules"],
      "Resource": ["*"] },
    { "Sid": "EventsOn3amRules", "Effect": "Allow",
      "Action": ["events:*"],
      "Resource": ["arn:${PARTITION}:events:*:${ACCOUNT_ID}:rule/3am-*"] },
    { "Sid": "KmsCreate3amTaggedKeys", "Effect": "Allow",
      "Action": ["kms:CreateKey","kms:TagResource"],
      "Resource": ["*"],
      "Condition": { "StringEquals": { "aws:RequestTag/Service": "3am" } } },
    { "Sid": "KmsListAccountScope", "Effect": "Allow",
      "Action": ["kms:ListAliases","kms:ListKeys"],
      "Resource": ["*"] },
    { "Sid": "KmsOn3amKeysAndAliases", "Effect": "Allow",
      "Action": ["kms:*"],
      "Resource": ["arn:${PARTITION}:kms:*:${ACCOUNT_ID}:alias/3am-*",
                   "arn:${PARTITION}:kms:*:${ACCOUNT_ID}:key/*"] }
  ]
}
EOF

  log "writing ${PERMS_APPS_FILE}"
  cat > "${PERMS_APPS_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["iam:GetPolicy","iam:GetPolicyVersion","iam:ListPolicyVersions"],
      "Resource": ["arn:${PARTITION}:iam::aws:policy/*",
                   "arn:${PARTITION}:iam::aws:policy/service-role/*",
                   "arn:${PARTITION}:iam::aws:policy/aws-service-role/*",
                   "arn:${PARTITION}:iam::aws:policy/job-function/*"] },
    { "Effect": "Allow", "Action": ["lambda:*"],
      "Resource": ["arn:${PARTITION}:lambda:*:${ACCOUNT_ID}:function:*"] },
    { "Effect": "Allow", "Action": ["iam:*"],
      "Resource": ["arn:${PARTITION}:iam::${ACCOUNT_ID}:role/*",
                   "arn:${PARTITION}:iam::${ACCOUNT_ID}:policy/*"] },
    { "Effect": "Allow",
      "Action": ["iam:GetAccountPasswordPolicy","iam:UpdateAccountPasswordPolicy",
                 "iam:DeleteAccountPasswordPolicy"],
      "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["rds:*"],
      "Resource": ["arn:${PARTITION}:rds:*:${ACCOUNT_ID}:*"] },
    { "Effect": "Allow", "Action": ["secretsmanager:*"], "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["ses:*"], "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["sqs:*"],
      "Resource": ["arn:${PARTITION}:sqs:*:${ACCOUNT_ID}:*"] },
    { "Sid": "DynamoDBOn3amTables", "Effect": "Allow", "Action": ["dynamodb:*"],
      "Resource": ["arn:${PARTITION}:dynamodb:*:${ACCOUNT_ID}:table/3am-*"] },
    { "Effect": "Allow",
      "Action": ["s3:GetAccountPublicAccessBlock","s3:PutAccountPublicAccessBlock"],
      "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["s3:*"],
      "Resource": [
        "arn:${PARTITION}:s3:::3am-*","arn:${PARTITION}:s3:::3am-*/*",
        "arn:${PARTITION}:s3:::alb-*-3am-*","arn:${PARTITION}:s3:::alb-*-3am-*/*",
        "arn:${PARTITION}:s3:::trail-*","arn:${PARTITION}:s3:::trail-*/*",
        "arn:${PARTITION}:s3:::*.3amops.com","arn:${PARTITION}:s3:::*.3amops.com/*"
      ] },
    { "Effect": "Allow",
      "Action": ["kms:CreateKey","kms:TagResource","kms:UntagResource",
                 "kms:EnableKeyRotation","kms:DisableKeyRotation",
                 "kms:ScheduleKeyDeletion","kms:CancelKeyDeletion"],
      "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["kms:*"],
      "Resource": ["arn:${PARTITION}:kms:*:${ACCOUNT_ID}:alias/xpki/*"] },
    { "Effect": "Allow", "Action": ["events:ListRules"], "Resource": ["*"] },
    { "Effect": "Allow", "Action": ["events:*"],
      "Resource": ["arn:${PARTITION}:events:*:${ACCOUNT_ID}:rule/*"] },
    { "Effect": "Allow", "Action": ["elasticloadbalancing:*"], "Resource": ["*"] }
  ]
}
EOF

  log "writing ${CMK_POLICY_FILE}"
  # Customer admin role ARNs are passed in as a JSON array; the
  # AllowCustomerAdminsKeyManagement statement is omitted when empty
  # (matches deploy/kms.tf's dynamic block).
  if [ "${admin_arns_json}" = "[]" ] || [ -z "${admin_arns_json}" ]; then
    cat > "${CMK_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EnableIAMUserPermissions", "Effect": "Allow",
      "Principal": { "AWS": "arn:${PARTITION}:iam::${ACCOUNT_ID}:root" },
      "Action": "kms:*", "Resource": "*" },
    { "Sid": "AllowAxelspireDeploymentRoleDataPlane", "Effect": "Allow",
      "Principal": { "AWS": "${DEPLOYMENT_ROLE_ARN}" },
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                 "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext","kms:DescribeKey"],
      "Resource": "*" },
    { "Sid": "AllowLambdaServiceUseInThisAccount", "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                 "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext",
                 "kms:DescribeKey","kms:CreateGrant"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "lambda.${DEPLOYMENT_REGION}.amazonaws.com",
          "kms:CallerAccount": "${ACCOUNT_ID}"
        }
      } },
    { "Sid": "AllowS3ServiceUseInThisAccount", "Effect": "Allow",
      "Principal": { "Service": "s3.amazonaws.com" },
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                 "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext","kms:DescribeKey"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "s3.${DEPLOYMENT_REGION}.amazonaws.com",
          "kms:CallerAccount": "${ACCOUNT_ID}"
        }
      } }
  ]
}
EOF
  else
    cat > "${CMK_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EnableIAMUserPermissions", "Effect": "Allow",
      "Principal": { "AWS": "arn:${PARTITION}:iam::${ACCOUNT_ID}:root" },
      "Action": "kms:*", "Resource": "*" },
    { "Sid": "AllowCustomerAdminsKeyManagement", "Effect": "Allow",
      "Principal": { "AWS": ${admin_arns_json} },
      "Action": ["kms:Create*","kms:Describe*","kms:Enable*","kms:List*","kms:Put*",
                 "kms:Update*","kms:Revoke*","kms:Disable*","kms:Get*","kms:Delete*",
                 "kms:TagResource","kms:UntagResource","kms:ScheduleKeyDeletion","kms:CancelKeyDeletion"],
      "Resource": "*" },
    { "Sid": "AllowAxelspireDeploymentRoleDataPlane", "Effect": "Allow",
      "Principal": { "AWS": "${DEPLOYMENT_ROLE_ARN}" },
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                 "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext","kms:DescribeKey"],
      "Resource": "*" },
    { "Sid": "AllowLambdaServiceUseInThisAccount", "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                 "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext",
                 "kms:DescribeKey","kms:CreateGrant"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "lambda.${DEPLOYMENT_REGION}.amazonaws.com",
          "kms:CallerAccount": "${ACCOUNT_ID}"
        }
      } },
    { "Sid": "AllowS3ServiceUseInThisAccount", "Effect": "Allow",
      "Principal": { "Service": "s3.amazonaws.com" },
      "Action": ["kms:Encrypt","kms:Decrypt","kms:ReEncryptFrom","kms:ReEncryptTo",
                 "kms:GenerateDataKey","kms:GenerateDataKeyWithoutPlaintext","kms:DescribeKey"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "s3.${DEPLOYMENT_REGION}.amazonaws.com",
          "kms:CallerAccount": "${ACCOUNT_ID}"
        }
      } }
  ]
}
EOF
  fi

  log "writing ${STATE_BUCKET_POLICY_FILE}"
  cat > "${STATE_BUCKET_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "DenyInsecureTransport", "Effect": "Deny",
      "Principal": "*", "Action": "s3:*",
      "Resource": ["arn:${PARTITION}:s3:::${STATE_BUCKET_NAME}",
                   "arn:${PARTITION}:s3:::${STATE_BUCKET_NAME}/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } } }
  ]
}
EOF

  phase5_assert_inline_policy_sizes

  if command -v python3 >/dev/null 2>&1; then
    local f
    for f in "${TRUST_POLICY_FILE}" "${PERMS_POLICY_FILE}" "${PERMS_EC2_FILE}" \
             "${PERMS_EXTRA_FILE}" "${PERMS_ONBOARDING_FILE}" "${PERMS_INFRA_FILE}" \
             "${PERMS_APPS_FILE}" "${CMK_POLICY_FILE}" "${STATE_BUCKET_POLICY_FILE}"; do
      python3 -m json.tool < "${f}" > /dev/null || die "generated ${f} is not valid JSON"
    done
  fi
}

# ---------------------------------------------------------------------------
# Phase 5 — idempotent resource helpers
# ---------------------------------------------------------------------------
phase5_common_tags_cli () {
  # Returns AWS-CLI --tags-style argument list. Used by services whose
  # Create* call accepts tags inline.
  echo "Key=Service,Value=3am Key=CustomerId,Value=${CUSTOMER_ID} Key=ManagedBy,Value=single-account-setup.sh Key=BootstrapVersion,Value=${BOOTSTRAP_VERSION}"
}

phase5_get_or_create_deployment_role () {
  local arn
  if aws iam get-role --role-name "${DEPLOYMENT_ROLE_NAME}" >/dev/null 2>&1; then
    log "reusing IAM role ${DEPLOYMENT_ROLE_NAME}; updating trust policy"
    aws iam update-assume-role-policy \
      --role-name "${DEPLOYMENT_ROLE_NAME}" \
      --policy-document "file://${TRUST_POLICY_FILE}" >/dev/null
  else
    log "creating IAM role ${DEPLOYMENT_ROLE_NAME}"
    # shellcheck disable=SC2046
    aws iam create-role \
      --role-name "${DEPLOYMENT_ROLE_NAME}" \
      --assume-role-policy-document "file://${TRUST_POLICY_FILE}" \
      --description "Cross-account role assumed by AxelSpire CI to deploy 3AM resources for ${CUSTOMER_ID}." \
      --max-session-duration 3600 \
      --tags $(phase5_common_tags_cli) >/dev/null
  fi
  arn=$(aws iam get-role --role-name "${DEPLOYMENT_ROLE_NAME}" \
          --query 'Role.Arn' --output text)
  DEPLOYMENT_ROLE_ARN="${arn}"
}

phase5_put_role_inline_policies () {
  log "putting inline policies on ${DEPLOYMENT_ROLE_NAME}"
  aws iam put-role-policy --role-name "${DEPLOYMENT_ROLE_NAME}" \
    --policy-name ThreeAM-Deployment-Permissions \
    --policy-document "file://${PERMS_POLICY_FILE}" >/dev/null
  aws iam put-role-policy --role-name "${DEPLOYMENT_ROLE_NAME}" \
    --policy-name ThreeAM-Deployment-Permissions-Ec2 \
    --policy-document "file://${PERMS_EC2_FILE}" >/dev/null
  aws iam put-role-policy --role-name "${DEPLOYMENT_ROLE_NAME}" \
    --policy-name ThreeAM-Deployment-Permissions-Extra \
    --policy-document "file://${PERMS_EXTRA_FILE}" >/dev/null
  aws iam put-role-policy --role-name "${DEPLOYMENT_ROLE_NAME}" \
    --policy-name ThreeAM-Deployment-Permissions-Onboarding \
    --policy-document "file://${PERMS_ONBOARDING_FILE}" >/dev/null
  aws iam put-role-policy --role-name "${DEPLOYMENT_ROLE_NAME}" \
    --policy-name ThreeAM-Deployment-Permissions-Infra \
    --policy-document "file://${PERMS_INFRA_FILE}" >/dev/null
  aws iam put-role-policy --role-name "${DEPLOYMENT_ROLE_NAME}" \
    --policy-name ThreeAM-Deployment-Permissions-Apps \
    --policy-document "file://${PERMS_APPS_FILE}" >/dev/null
}

# Read-only companion to ThreeAM-Deployment. Created during bootstrap so
# the per-customer CI CMK key policy can reference a valid principal
# before customer-deploy onboarding runs. Mirrors deploy/iam-drift-reader.tf.
phase5_write_drift_reader_policy_files () {
  log "writing ${DRIFT_TRUST_POLICY_FILE}"
  cat > "${DRIFT_TRUST_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowAxelspireDriftDetectAssumeRole",
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:${PARTITION}:iam::${AXELSPIRE_CI_ACCOUNT_ID}:role/${AXELSPIRE_CI_DRIFT_ROLE_NAME}"
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringLike": { "sts:RoleSessionName": ["3am-*", "tg-*"] }
    }
  }]
}
EOF
  python3 -m json.tool "${DRIFT_TRUST_POLICY_FILE}" >/dev/null

  log "writing ${DRIFT_STATE_POLICY_FILE}"
  cat > "${DRIFT_STATE_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ReadOnStateBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:GetBucketVersioning",
        "s3:GetEncryptionConfiguration",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:${PARTITION}:s3:::${STATE_BUCKET_NAME}",
        "arn:${PARTITION}:s3:::${STATE_BUCKET_NAME}/*"
      ]
    },
    {
      "Sid": "DynamoDBLockOnStateLockTable",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": "arn:${PARTITION}:dynamodb:${DEPLOYMENT_REGION}:${ACCOUNT_ID}:table/${STATE_LOCK_TABLE_NAME}"
    },
    {
      "Sid": "KmsDecryptOnCustomerCmk",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:DescribeKey"],
      "Resource": "${CUSTOMER_CMK_ARN}"
    },
    {
      "Sid": "KmsDecryptOnAxelspireCiCmk",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:DescribeKey"],
      "Resource": "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
    }
  ]
}
EOF
  python3 -m json.tool "${DRIFT_STATE_POLICY_FILE}" >/dev/null

  # Workload-read permissions for tofu refresh on resources whose APIs
  # are not in the AWS-managed ReadOnlyAccess policy:
  #   - secretsmanager:GetSecretValue : aws_secretsmanager_secret_version
  #     (3am-core/deploy/modules/secrets, 3am-ca-kms/deploy/secrets.tf)
  #     and data.aws_secretsmanager_secret_version (external_id).
  #   - kms:Decrypt via aws/ssm : data.aws_ssm_parameter with
  #     with_decryption=true on SecureString params encrypted by the
  #     AWS-managed aws/ssm key (e.g. 3am-internal internal_access_key).
  # kms:ViaService bounds the Decrypt grant to those two services so the
  # role cannot decrypt arbitrary KMS keys directly.
  log "writing ${DRIFT_WORKLOAD_POLICY_FILE}"
  cat > "${DRIFT_WORKLOAD_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerGetSecretValue",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "*"
    },
    {
      "Sid": "KmsDecryptViaAwsManagedServiceKeys",
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "kms:ViaService": [
            "ssm.*.amazonaws.com",
            "secretsmanager.*.amazonaws.com"
          ]
        }
      }
    }
  ]
}
EOF
  python3 -m json.tool "${DRIFT_WORKLOAD_POLICY_FILE}" >/dev/null
}

phase5_get_or_create_drift_reader_role () {
  local arn
  if aws iam get-role --role-name "${DRIFT_READER_ROLE_NAME}" >/dev/null 2>&1; then
    log "reusing IAM role ${DRIFT_READER_ROLE_NAME}; updating trust policy"
    aws iam update-assume-role-policy \
      --role-name "${DRIFT_READER_ROLE_NAME}" \
      --policy-document "file://${DRIFT_TRUST_POLICY_FILE}" >/dev/null
  else
    log "creating IAM role ${DRIFT_READER_ROLE_NAME}"
    # shellcheck disable=SC2046
    aws iam create-role \
      --role-name "${DRIFT_READER_ROLE_NAME}" \
      --assume-role-policy-document "file://${DRIFT_TRUST_POLICY_FILE}" \
      --description "Read-only cross-account role assumed by AxelSpire drift-detect for ${CUSTOMER_ID}." \
      --max-session-duration 3600 \
      --tags $(phase5_common_tags_cli) >/dev/null
  fi
  arn=$(aws iam get-role --role-name "${DRIFT_READER_ROLE_NAME}" \
          --query 'Role.Arn' --output text)
  DRIFT_READER_ROLE_ARN="${arn}"
}

phase5_put_drift_reader_policies () {
  log "putting inline policies on ${DRIFT_READER_ROLE_NAME}"
  aws iam attach-role-policy --role-name "${DRIFT_READER_ROLE_NAME}" \
    --policy-arn "arn:${PARTITION}:iam::aws:policy/ReadOnlyAccess" >/dev/null 2>&1 \
    || true
  aws iam put-role-policy --role-name "${DRIFT_READER_ROLE_NAME}" \
    --policy-name ThreeAM-DriftReader-State \
    --policy-document "file://${DRIFT_STATE_POLICY_FILE}" >/dev/null
  log "  ThreeAM-DriftReader-State CI CMK = ${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
  log "  (must match 3am-deployments customers/<id>/customer.hcl bootstrap.artifact_kms_key_arn and CI key policy AllowCustomerDriftReaderDecrypt)"
  aws iam put-role-policy --role-name "${DRIFT_READER_ROLE_NAME}" \
    --policy-name ThreeAM-DriftReader-Workload-Read \
    --policy-document "file://${DRIFT_WORKLOAD_POLICY_FILE}" >/dev/null
}

# CMK lookup-by-alias then create-if-missing. Re-applies the key policy
# on every run so trust changes (rotated admin role ARNs, etc.) take
# effect. Key rotation is enabled if not already.
phase5_get_or_create_cmk () {
  local key_id mr_flag=""
  ${KMS_MULTI_REGION} && mr_flag="--multi-region"
  key_id=$(aws kms describe-key --key-id "${CUSTOMER_CMK_ALIAS}" \
            --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo "")
  if [ -z "${key_id}" ]; then
    log "creating customer CMK ${CUSTOMER_CMK_ALIAS}"
    # shellcheck disable=SC2046,SC2086
    key_id=$(aws kms create-key \
              --description "3AM customer-managed CMK for ${CUSTOMER_ID}" \
              ${mr_flag} \
              --tags $(phase5_common_tags_cli | sed 's/Key=/TagKey=/g; s/Value=/TagValue=/g') \
              --query 'KeyMetadata.KeyId' --output text)
    aws kms create-alias \
      --alias-name "${CUSTOMER_CMK_ALIAS}" \
      --target-key-id "${key_id}" >/dev/null
  else
    log "reusing customer CMK ${CUSTOMER_CMK_ALIAS} (key-id ${key_id})"
  fi
  CUSTOMER_CMK_KEY_ID="${key_id}"
  CUSTOMER_CMK_ARN=$(aws kms describe-key --key-id "${key_id}" \
                       --query 'KeyMetadata.Arn' --output text)
  aws kms enable-key-rotation --key-id "${key_id}" >/dev/null 2>&1 || true
}

phase5_put_cmk_policy () {
  # KMS validates every Principal ARN against IAM synchronously. The
  # ThreeAM-Deployment role is created moments before this call, and
  # AWSReservedSSO_* roles can be similarly fresh, so KMS may still
  # see them as "invalid principal" for a few seconds. Retry on that
  # specific error with bounded backoff; any other error fails fast.
  log "putting key policy on ${CUSTOMER_CMK_ALIAS}"
  local attempts=8 i=1 err
  while :; do
    err=$(aws kms put-key-policy \
            --key-id "${CUSTOMER_CMK_KEY_ID}" \
            --policy-name default \
            --policy "file://${CMK_POLICY_FILE}" 2>&1 >/dev/null) && return 0
    if ! echo "${err}" | grep -q "MalformedPolicyDocumentException"; then
      echo "${err}" >&2
      die "put-key-policy failed on ${CUSTOMER_CMK_ALIAS}"
    fi
    [ ${i} -ge ${attempts} ] && { echo "${err}" >&2; \
      die "put-key-policy: principals still invalid after $((attempts*8))s (check PA/BG/ThreeAM-Deployment ARNs in ${CMK_POLICY_FILE})"; }
    log "  …KMS reports invalid principal (attempt ${i}/${attempts}); waiting 8s for IAM propagation"
    sleep 8
    i=$((i+1))
  done
}

# Secrets Manager: create the external-ID secret with a random 32-byte
# hex value on first run; leave the value alone on subsequent runs.
phase5_get_or_create_external_id_secret () {
  local arn
  arn=$(aws secretsmanager describe-secret \
          --secret-id "${EXTERNAL_ID_SECRET_NAME}" \
          --query 'ARN' --output text 2>/dev/null || echo "")
  if [ -n "${arn}" ] && [ "${arn}" != "None" ]; then
    log "reusing external-ID secret ${EXTERNAL_ID_SECRET_NAME}"
    EXTERNAL_ID_SECRET_ARN="${arn}"
    return
  fi
  command -v openssl >/dev/null 2>&1 || die "openssl required to generate external-ID secret value"
  log "creating external-ID secret ${EXTERNAL_ID_SECRET_NAME} (32-byte hex)"
  local secret_value
  secret_value=$(openssl rand -hex 32)
  # shellcheck disable=SC2046
  arn=$(aws secretsmanager create-secret \
          --name "${EXTERNAL_ID_SECRET_NAME}" \
          --description "External ID for AssumeRole into ${DEPLOYMENT_ROLE_NAME}" \
          --kms-key-id "${CUSTOMER_CMK_ARN}" \
          --secret-string "${secret_value}" \
          --tags $(phase5_common_tags_cli | sed 's/Key=/Key=/g') \
          --query 'ARN' --output text)
  EXTERNAL_ID_SECRET_ARN="${arn}"
}

phase5_read_external_id_value () {
  aws secretsmanager get-secret-value \
    --secret-id "${EXTERNAL_ID_SECRET_ARN}" \
    --query 'SecretString' --output text
}

phase5_get_or_create_state_bucket () {
  STATE_BUCKET_NAME="3am-state-${ACCOUNT_ID}-${DEPLOYMENT_REGION}"
  if aws s3api head-bucket --bucket "${STATE_BUCKET_NAME}" --region "${DEPLOYMENT_REGION}" 2>/dev/null; then
    log "reusing state bucket ${STATE_BUCKET_NAME}"
  else
    log "creating state bucket ${STATE_BUCKET_NAME}"
    if [ "${DEPLOYMENT_REGION}" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "${STATE_BUCKET_NAME}" --region "${DEPLOYMENT_REGION}" >/dev/null
    else
      aws s3api create-bucket --bucket "${STATE_BUCKET_NAME}" --region "${DEPLOYMENT_REGION}" \
        --create-bucket-configuration "LocationConstraint=${DEPLOYMENT_REGION}" >/dev/null
    fi
  fi

  log "applying ownership / public-access / versioning / encryption / lifecycle / policy"
  aws s3api put-bucket-ownership-controls --bucket "${STATE_BUCKET_NAME}" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' >/dev/null
  aws s3api put-public-access-block --bucket "${STATE_BUCKET_NAME}" \
    --public-access-block-configuration \
      'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
  aws s3api put-bucket-versioning --bucket "${STATE_BUCKET_NAME}" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "${STATE_BUCKET_NAME}" \
    --server-side-encryption-configuration "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}\"},\"BucketKeyEnabled\":true}]}" >/dev/null
  aws s3api put-bucket-lifecycle-configuration --bucket "${STATE_BUCKET_NAME}" \
    --lifecycle-configuration '{"Rules":[{"ID":"transition-noncurrent-to-glacier","Status":"Enabled","Filter":{},"NoncurrentVersionTransitions":[{"NoncurrentDays":90,"StorageClass":"GLACIER"}],"NoncurrentVersionExpiration":{"NoncurrentDays":365}}]}' >/dev/null
  aws s3api put-bucket-policy --bucket "${STATE_BUCKET_NAME}" \
    --policy "file://${STATE_BUCKET_POLICY_FILE}" >/dev/null
  aws s3api put-bucket-tagging --bucket "${STATE_BUCKET_NAME}" \
    --tagging "TagSet=[{Key=Service,Value=3am},{Key=CustomerId,Value=${CUSTOMER_ID}},{Key=ManagedBy,Value=single-account-setup.sh},{Key=BootstrapVersion,Value=${BOOTSTRAP_VERSION}}]" >/dev/null
}

phase5_get_or_create_lock_table () {
  # The lock table holds only Terraform lock IDs and digests (no state
  # contents), so encrypting it under the customer CMK is sufficient and
  # avoids requiring the bootstrap caller to be authorized on the
  # AxelSpire CI CMK. State objects in S3 remain encrypted under
  # AXELSPIRE_ARTIFACT_KMS_KEY_ARN, which is what carries the
  # "destroy-key-to-revoke-state" property.
  if aws dynamodb describe-table --table-name "${STATE_LOCK_TABLE_NAME}" >/dev/null 2>&1; then
    log "reusing lock table ${STATE_LOCK_TABLE_NAME}"
  else
    log "creating lock table ${STATE_LOCK_TABLE_NAME} (PAY_PER_REQUEST, SSE-KMS=customer CMK, PITR)"
    aws dynamodb create-table \
      --table-name "${STATE_LOCK_TABLE_NAME}" \
      --billing-mode PAY_PER_REQUEST \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --sse-specification "Enabled=true,SSEType=KMS,KMSMasterKeyId=${CUSTOMER_CMK_ARN}" \
      --tags "Key=Service,Value=3am" "Key=CustomerId,Value=${CUSTOMER_ID}" \
             "Key=ManagedBy,Value=single-account-setup.sh" \
             "Key=BootstrapVersion,Value=${BOOTSTRAP_VERSION}" >/dev/null
    log "waiting for lock table ACTIVE"
    aws dynamodb wait table-exists --table-name "${STATE_LOCK_TABLE_NAME}"
    aws dynamodb update-continuous-backups --table-name "${STATE_LOCK_TABLE_NAME}" \
      --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true >/dev/null 2>&1 || true
  fi
}

phase5_put_ssm_params () {
  log "publishing /3am/* SSM parameters"
  _put_ssm () {
    local name=$1 desc=$2 value=$3 type=${4:-String} key_id=${5:-}
    if [ "${type}" = "SecureString" ] && [ -n "${key_id}" ]; then
      aws ssm put-parameter --name "${name}" --description "${desc}" \
        --type "${type}" --key-id "${key_id}" --overwrite --value "${value}" >/dev/null
    else
      aws ssm put-parameter --name "${name}" --description "${desc}" \
        --type "${type}" --overwrite --value "${value}" >/dev/null
    fi
  }
  _put_ssm /3am/kms/customer-cmk-arn  "ARN of the customer-managed CMK."  "${CUSTOMER_CMK_ARN}"
  _put_ssm /3am/kms/customer-cmk-id   "Key ID of the customer-managed CMK." "${CUSTOMER_CMK_KEY_ID}"
  _put_ssm /3am/state/bucket-name     "Name of the S3 bucket holding Terraform state." "${STATE_BUCKET_NAME}"
  _put_ssm /3am/state/lock-table-name "Name of the DynamoDB state-lock table." "${STATE_LOCK_TABLE_NAME}"
  _put_ssm /3am/iam/deployment-role-arn "ARN of the ${DEPLOYMENT_ROLE_NAME} role." "${DEPLOYMENT_ROLE_ARN}"
  _put_ssm /3am/iam/drift-reader-role-arn "ARN of the ${DRIFT_READER_ROLE_NAME} role." "${DRIFT_READER_ROLE_ARN}"
  _put_ssm /3am/axelspire/artifact-kms-key-arn   "Key-ID ARN of the customer-region MRK replica of the AxelSpire-owned CI CMK." "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
  _put_ssm /3am/axelspire/artifact-s3-bucket-arn "ARN of the AxelSpire CI artifacts S3 bucket." "${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}"
  _put_ssm /3am/bootstrap/version     "Version of the bootstrap that was last applied." "${BOOTSTRAP_VERSION}"
  _put_ssm /3am/bootstrap/applied-at  "Timestamp of the last apply of the bootstrap." "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Main Phase 5 entry-point. Assumes preflight has resolved ACCOUNT_ID,
# PARTITION, EFFECTIVE_REGION, DEPLOYMENT_REGION and (for the CMK admin
# statement) the AWSReservedSSO role ARNs. AWS_REGION is pivoted to
# DEPLOYMENT_REGION for the duration of phase 5 so all regional AWS CLI
# calls (kms, secretsmanager, s3, dynamodb, ssm) target the deployment
# region, even when it differs from the Identity Center home region.
phase5_apply () {
  phase5_compute_axelspire_arns

  log "Phase 5: AxelSpire artifact KMS key = ${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
  log "Phase 5: AxelSpire artifact S3 bucket = ${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}"

  local _saved_region _saved_region_set
  if [ -n "${AWS_REGION+x}" ]; then
    _saved_region="${AWS_REGION}"; _saved_region_set=true
  else
    _saved_region=""; _saved_region_set=false
  fi
  export AWS_REGION="${DEPLOYMENT_REGION}"
  log "Phase 5: AWS_REGION pinned to ${DEPLOYMENT_REGION} (deployment region)"

  STATE_BUCKET_NAME="3am-state-${ACCOUNT_ID}-${DEPLOYMENT_REGION}"

  # Step 1: KMS CMK (needed by Secrets Manager for the external-ID
  # secret and referenced by the inline role policy).
  # We need a placeholder role ARN before writing the CMK policy, so
  # compute the ARN string ahead of the role actually existing. AWS
  # accepts the string at policy-write time.
  DEPLOYMENT_ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT_ID}:role/${DEPLOYMENT_ROLE_NAME}"

  # Collect customer admin role ARNs from Phase 0 outputs (PA / BG roles).
  # The AllowCustomerAdminsKeyManagement statement is omitted when none.
  local admin_arns_json="[]"
  if command -v jq >/dev/null 2>&1; then
    admin_arns_json=$(jq -nc \
      --arg pa "${PA_ROLE_ARN}" --arg bg "${BG_ROLE_ARN}" \
      '[$pa,$bg] | map(select(. != ""))')
  else
    local pa_csv="" bg_csv=""
    [ -n "${PA_ROLE_ARN}" ] && pa_csv="\"${PA_ROLE_ARN}\""
    [ -n "${BG_ROLE_ARN}" ] && bg_csv="\"${BG_ROLE_ARN}\""
    case "${pa_csv}${bg_csv}" in
      "") admin_arns_json="[]" ;;
      *)
        if [ -n "${pa_csv}" ] && [ -n "${bg_csv}" ]; then
          admin_arns_json="[${pa_csv},${bg_csv}]"
        else
          admin_arns_json="[${pa_csv}${bg_csv}]"
        fi
        ;;
    esac
  fi

  # Phase 5 step 1: customer CMK (needs CUSTOMER_CMK_ARN before policies
  # that reference it; the policy file uses placeholders).
  log "== Phase 5 step 1/6: customer CMK =="
  # Initial CMK creation uses a minimal account-root policy; we refresh
  # it at the end once DEPLOYMENT_ROLE_ARN and CUSTOMER_CMK_ARN are real.
  if ! aws kms describe-key --key-id "${CUSTOMER_CMK_ALIAS}" >/dev/null 2>&1; then
    local minimal_policy="/tmp/3am-customer-cmk-minimal.json"
    cat > "${minimal_policy}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "EnableIAMUserPermissions", "Effect": "Allow",
    "Principal": { "AWS": "arn:${PARTITION}:iam::${ACCOUNT_ID}:root" },
    "Action": "kms:*", "Resource": "*"
  }]
}
EOF
    local mr_flag="" key_id
    ${KMS_MULTI_REGION} && mr_flag="--multi-region"
    log "creating customer CMK ${CUSTOMER_CMK_ALIAS}"
    # shellcheck disable=SC2086
    key_id=$(aws kms create-key \
              --description "3AM customer-managed CMK for ${CUSTOMER_ID}" \
              ${mr_flag} \
              --policy "file://${minimal_policy}" \
              --tags "TagKey=Service,TagValue=3am" \
                     "TagKey=CustomerId,TagValue=${CUSTOMER_ID}" \
                     "TagKey=ManagedBy,TagValue=single-account-setup.sh" \
                     "TagKey=BootstrapVersion,TagValue=${BOOTSTRAP_VERSION}" \
              --query 'KeyMetadata.KeyId' --output text)
    aws kms create-alias --alias-name "${CUSTOMER_CMK_ALIAS}" --target-key-id "${key_id}" >/dev/null
    CUSTOMER_CMK_KEY_ID="${key_id}"
  else
    CUSTOMER_CMK_KEY_ID=$(aws kms describe-key --key-id "${CUSTOMER_CMK_ALIAS}" \
                            --query 'KeyMetadata.KeyId' --output text)
    log "reusing customer CMK ${CUSTOMER_CMK_ALIAS} (key-id ${CUSTOMER_CMK_KEY_ID})"
  fi
  CUSTOMER_CMK_ARN=$(aws kms describe-key --key-id "${CUSTOMER_CMK_KEY_ID}" \
                       --query 'KeyMetadata.Arn' --output text)
  aws kms enable-key-rotation --key-id "${CUSTOMER_CMK_KEY_ID}" >/dev/null 2>&1 || true

  log "== Phase 5 step 2/6: external-ID secret =="
  phase5_get_or_create_external_id_secret
  local external_id_value
  external_id_value=$(phase5_read_external_id_value)

  log "== Phase 5 step 3/6: ThreeAM-Deployment role =="
  # Write the policy files now that we know STATE_BUCKET_NAME,
  # CUSTOMER_CMK_ARN and external-ID value.
  phase5_write_policy_files "${external_id_value}" "${admin_arns_json}"
  phase5_get_or_create_deployment_role
  phase5_put_role_inline_policies

  log "== Phase 5 step 4/6: CMK key policy (now that role exists) =="
  # Regenerate CMK policy with the real role ARN principal and re-apply.
  phase5_write_policy_files "${external_id_value}" "${admin_arns_json}"
  phase5_put_cmk_policy

  log "== Phase 5 step 5/7: state bucket + lock table =="
  phase5_get_or_create_state_bucket
  phase5_get_or_create_lock_table

  log "== Phase 5 step 6/7: ThreeAM-DriftReader role =="
  phase5_write_drift_reader_policy_files
  phase5_get_or_create_drift_reader_role
  phase5_put_drift_reader_policies

  log "== Phase 5 step 7/7: SSM parameters =="
  phase5_put_ssm_params

  if ${_saved_region_set}; then
    export AWS_REGION="${_saved_region}"
  else
    unset AWS_REGION
  fi
  log "Phase 5: AWS_REGION restored (now operating in ${AWS_REGION:-<unset>})"
}



# ---------------------------------------------------------------------------
# apply — full setup, idempotent
# ---------------------------------------------------------------------------
do_apply () {
  if ! ${SKIP_ORG} && ! ${EXTERNAL_IDP}; then
    [ -n "$BREAKGLASS_USER" ] || die "--breakglass-user required (or pass --external-idp / --skip-org)"
  fi
  # --axelspire-artifact-kms-key-arn is required on apply (key-ID ARN of
  # the customer-region MRK replica; see phase5_validate_axelspire_kms_arn).

  preflight
  resolve_apply_defaults

  say
  say "Customer:           ${CUSTOMER_NAME}"
  say "Customer ID slug:   ${CUSTOMER_ID}"
  say "Target account:     ${ACCOUNT_ID} (current caller — used as workload account)"
  say "Effective region:   ${EFFECTIVE_REGION} (IDC / Organizations)"
  say "Deployment region:  ${DEPLOYMENT_REGION} (state bucket, lock table, CMK)"
  say "Allowed regions:    ${ALLOWED_REGIONS_CSV}"
  say "Identity Center:    ${INSTANCE_ARN:-<n/a — skip-org>}"
  say "Platform admin:     ${PLATFORM_ADMIN_USER:-<external IdP / skip-org>}"
  say "Break-glass:        ${BREAKGLASS_USER:-<external IdP / skip-org>}"
  say "External IdP:       ${EXTERNAL_IDP}"
  say "Skip Phase 0 (org): ${SKIP_ORG}"
  say "Skip SCPs:          ${SKIP_SCPS}"
  say "Skip Phase 5:       ${SKIP_BOOTSTRAP}"
  say "AxelSpire CI acct:  ${AXELSPIRE_CI_ACCOUNT_ID} (${AXELSPIRE_CI_REGION})"
  say "Script version:     ${BOOTSTRAP_VERSION} (${BOOTSTRAP_VARIANT})"
  say "Script last updated: ${SCRIPT_LAST_UPDATED}"
  say
  if ! ${AUTO_APPROVE}; then
    read -r -p "Proceed? [y/N] " ans
    [ "${ans:-}" = "y" ] || die "aborted by operator"
  fi

  if ${SKIP_ORG}; then
    log "== Phase 0 skipped (--skip-org) =="
  else
    if ${SKIP_SCPS}; then
      log "== Phase 0 step 1/4: SCPs (skipped, --skip-scps) =="
    else
      log "== Phase 0 step 1/4: SCPs =="
      write_policy_files
      REGION_POLICY_ID=$(get_or_create_scp 3am-region-deny    "${REGION_POLICY_FILE}")
      ROOT_POLICY_ID=$(get_or_create_scp   3am-root-user-deny "${ROOT_POLICY_FILE}")
      # Attach to root: no-op for the management account itself (SCPs do
      # not apply there) but inherited by any future child accounts.
      attach_policy_if_missing "${REGION_POLICY_ID}" "${ROOT_ID}"
      attach_policy_if_missing "${ROOT_POLICY_ID}"   "${ROOT_ID}"
    fi

    log "== Phase 0 step 2/4: permission sets =="
    PS_PLATFORM_ARN=$(get_or_create_permission_set PlatformAdmin PT8H)
    PS_BREAKGLASS_ARN=$(get_or_create_permission_set BreakGlass  PT1H)
    attach_managed_policy_if_missing "${PS_PLATFORM_ARN}"   arn:aws:iam::aws:policy/AdministratorAccess
    attach_managed_policy_if_missing "${PS_BREAKGLASS_ARN}" arn:aws:iam::aws:policy/AdministratorAccess

    log "== Phase 0 step 3/4: groups / users =="
    if ${EXTERNAL_IDP}; then
      log "external IdP: looking up groups (expect SCIM to have synced them)"
      PA_GROUP_ID=$(lookup_group_required "${PLATFORM_ADMINS_GROUP}")
      BG_GROUP_ID=$(lookup_group_required "${BREAKGLASS_GROUP}")
    else
      PA_GROUP_ID=$(get_or_create_group "${PLATFORM_ADMINS_GROUP}")
      BG_GROUP_ID=$(get_or_create_group "${BREAKGLASS_GROUP}")
      PA_USER_ID=$(get_or_create_user "${PLATFORM_ADMIN_USER}")
      BG_USER_ID=$(get_or_create_user "${BREAKGLASS_USER}")
      ensure_group_membership "${PA_GROUP_ID}" "${PA_USER_ID}"
      ensure_group_membership "${BG_GROUP_ID}" "${BG_USER_ID}"
    fi

    log "== Phase 0 step 4/4: account assignments =="
    ensure_account_assignment "${ACCOUNT_ID}" "${PS_PLATFORM_ARN}"   GROUP "${PA_GROUP_ID}"
    ensure_account_assignment "${ACCOUNT_ID}" "${PS_BREAKGLASS_ARN}" GROUP "${BG_GROUP_ID}"

    log "== resolving AWSReservedSSO role ARNs (best-effort) =="
    PA_ROLE_ARN=$(resolve_reserved_sso_role_arn PlatformAdmin || true)
    BG_ROLE_ARN=$(resolve_reserved_sso_role_arn BreakGlass    || true)
  fi

  if ${SKIP_BOOTSTRAP}; then
    log "== Phase 5 skipped (--skip-bootstrap) =="
  else
    # Phase 5 — cross-account role, customer CMK, state backend, secret,
    # SSM parameters. PA_ROLE_ARN / BG_ROLE_ARN may still be empty when
    # Phase 0 was skipped or assignments haven't provisioned yet; the
    # CMK admin statement is omitted in that case (same shape as the
    # OpenTofu module's dynamic block).
    phase5_apply
  fi

  print_outputs_human
  print_outputs_json > "${LOG_DIR}/3am-single-account-setup-outputs.json"
  log "outputs JSON: ${LOG_DIR}/3am-single-account-setup-outputs.json"
  log "DONE."
}


# ---------------------------------------------------------------------------
# outputs — re-resolve everything from AWS so the command works in a
# fresh shell with no in-memory state.
# ---------------------------------------------------------------------------
resolve_outputs () {
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text 2>/dev/null || echo "")
  INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text 2>/dev/null || echo "")
  IDSTORE_ID=$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text 2>/dev/null || echo "")

  REGION_POLICY_ID=$(aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
                      --query 'Policies[?Name==`3am-region-deny`].Id | [0]' --output text 2>/dev/null || echo "")
  ROOT_POLICY_ID=$(aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
                    --query 'Policies[?Name==`3am-root-user-deny`].Id | [0]' --output text 2>/dev/null || echo "")

  if [ -n "${INSTANCE_ARN}" ] && [ "${INSTANCE_ARN}" != "None" ]; then
    local ps
    for ps in $(aws sso-admin list-permission-sets \
                  --instance-arn "${INSTANCE_ARN}" \
                  --query 'PermissionSets[]' --output text 2>/dev/null); do
      local n
      n=$(aws sso-admin describe-permission-set \
            --instance-arn "${INSTANCE_ARN}" --permission-set-arn "$ps" \
            --query 'PermissionSet.Name' --output text 2>/dev/null || echo "")
      [ "$n" = "PlatformAdmin" ] && PS_PLATFORM_ARN="$ps"
      [ "$n" = "BreakGlass"    ] && PS_BREAKGLASS_ARN="$ps"
    done

    PA_GROUP_ID=$(aws identitystore list-groups \
                  --identity-store-id "${IDSTORE_ID}" \
                  --filters AttributePath=DisplayName,AttributeValue="${PLATFORM_ADMINS_GROUP}" \
                  --query 'Groups[0].GroupId' --output text 2>/dev/null || echo "")
    BG_GROUP_ID=$(aws identitystore list-groups \
                  --identity-store-id "${IDSTORE_ID}" \
                  --filters AttributePath=DisplayName,AttributeValue="${BREAKGLASS_GROUP}" \
                  --query 'Groups[0].GroupId' --output text 2>/dev/null || echo "")
  fi

  PA_ROLE_ARN=$(resolve_reserved_sso_role_arn PlatformAdmin || true)
  BG_ROLE_ARN=$(resolve_reserved_sso_role_arn BreakGlass    || true)

  # Phase 5 outputs — re-resolve from AWS so this works from a fresh shell.
  PARTITION=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null | cut -d: -f2)
  [ -n "$PARTITION" ] || PARTITION="aws"
  EFFECTIVE_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
  # If --deployment-region was not passed, default to EFFECTIVE_REGION so
  # the bucket / KMS / Secrets lookups below target the right region. The
  # single-account variant has no child-account tag to recover from, so a
  # mismatched shell region with no flag will simply look in the wrong place.
  [ -n "${DEPLOYMENT_REGION}" ] || DEPLOYMENT_REGION="${EFFECTIVE_REGION}"
  if [ -z "$CUSTOMER_ID" ] && [ -n "$CUSTOMER_NAME" ]; then
    CUSTOMER_ID=$(printf '%s' "${CUSTOMER_NAME}" \
                    | tr '[:upper:]' '[:lower:]' \
                    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  fi
  [ -n "$CUSTOMER_ID" ] && phase5_compute_axelspire_arns
  DEPLOYMENT_ROLE_ARN=$(aws iam get-role --role-name "${DEPLOYMENT_ROLE_NAME}" \
                          --query 'Role.Arn' --output text 2>/dev/null || echo "")
  DRIFT_READER_ROLE_ARN=$(aws iam get-role --role-name "${DRIFT_READER_ROLE_NAME}" \
                            --query 'Role.Arn' --output text 2>/dev/null || echo "")
  CUSTOMER_CMK_KEY_ID=$(aws kms describe-key --key-id "${CUSTOMER_CMK_ALIAS}" \
                          --region "${DEPLOYMENT_REGION}" \
                          --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo "")
  if [ -n "$CUSTOMER_CMK_KEY_ID" ] && [ "$CUSTOMER_CMK_KEY_ID" != "None" ]; then
    CUSTOMER_CMK_ARN=$(aws kms describe-key --key-id "${CUSTOMER_CMK_KEY_ID}" \
                         --region "${DEPLOYMENT_REGION}" \
                         --query 'KeyMetadata.Arn' --output text 2>/dev/null || echo "")
  fi
  EXTERNAL_ID_SECRET_ARN=$(aws secretsmanager describe-secret \
                            --secret-id "${EXTERNAL_ID_SECRET_NAME}" \
                            --region "${DEPLOYMENT_REGION}" \
                            --query 'ARN' --output text 2>/dev/null || echo "")
  [ "$EXTERNAL_ID_SECRET_ARN" = "None" ] && EXTERNAL_ID_SECRET_ARN=""
  # Recover the AxelSpire CI CMK ARN from the SSM parameter written by
  # phase5_apply, so 'outputs' / 'outputs-json' invocations in a fresh
  # shell (no --axelspire-artifact-kms-key-arn) can still report it.
  if [ -z "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" ]; then
    AXELSPIRE_ARTIFACT_KMS_KEY_ARN=$(aws ssm get-parameter \
                                      --name /3am/axelspire/artifact-kms-key-arn \
                                      --region "${DEPLOYMENT_REGION}" \
                                      --query 'Parameter.Value' --output text 2>/dev/null || echo "")
    [ "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" = "None" ] && AXELSPIRE_ARTIFACT_KMS_KEY_ARN=""
  fi
  STATE_BUCKET_NAME="3am-state-${ACCOUNT_ID}-${DEPLOYMENT_REGION}"
  aws s3api head-bucket --bucket "${STATE_BUCKET_NAME}" --region "${DEPLOYMENT_REGION}" 2>/dev/null || STATE_BUCKET_NAME=""
}

print_outputs_human () {
  cat <<EOF

================================================================
  3AM single-account-setup — outputs
================================================================
  customer_name                       : ${CUSTOMER_NAME:-<unknown>}
  customer_id                         : ${CUSTOMER_ID:-<unknown>}
  account_id                          : ${ACCOUNT_ID:-<missing>}
  region                              : ${DEPLOYMENT_REGION:-<missing>}
  idc_region                          : ${EFFECTIVE_REGION:-<missing>}
  partition                           : ${PARTITION:-<missing>}

  Phase 0 (Identity Center / SCPs):
  identity_center_instance_arn        : ${INSTANCE_ARN:-<missing>}
  identity_store_id                   : ${IDSTORE_ID:-<missing>}
  region_deny_policy_id               : ${REGION_POLICY_ID:-<missing or skipped>}
  root_user_deny_policy_id            : ${ROOT_POLICY_ID:-<missing or skipped>}
  platform_admin_permission_set_arn   : ${PS_PLATFORM_ARN:-<missing>}
  breakglass_permission_set_arn       : ${PS_BREAKGLASS_ARN:-<missing>}
  platform_admins_group_id            : ${PA_GROUP_ID:-<missing>}
  breakglass_group_id                 : ${BG_GROUP_ID:-<missing>}
  platform_admin_role_arn             : ${PA_ROLE_ARN:-<pending — assignment not yet provisioned>}
  breakglass_role_arn                 : ${BG_ROLE_ARN:-<pending — assignment not yet provisioned>}

  Phase 5 (bootstrap):
  deployment_role_arn                 : ${DEPLOYMENT_ROLE_ARN:-<missing>}
  drift_reader_role_arn               : ${DRIFT_READER_ROLE_ARN:-<missing>}
  customer_cmk_arn                    : ${CUSTOMER_CMK_ARN:-<missing>}
  customer_cmk_alias                  : ${CUSTOMER_CMK_ALIAS}
  external_id_secret_arn              : ${EXTERNAL_ID_SECRET_ARN:-<missing>}
  state_bucket_name                   : ${STATE_BUCKET_NAME:-<missing>}
  state_lock_table_name               : ${STATE_LOCK_TABLE_NAME}
  axelspire_artifact_kms_key_arn      : ${AXELSPIRE_ARTIFACT_KMS_KEY_ARN:-<missing>}
  axelspire_artifact_s3_bucket_arn    : ${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN:-<missing>}
================================================================

Hand off to AxelSpire:
  Send the file 3am-single-account-setup-outputs.json (in ${LOG_DIR})
  to AxelSpire. It contains every ARN/ID needed to onboard this account
  in the AxelSpire customer-onboard workflow.
EOF
}

print_outputs_json () {
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg customer_name              "${CUSTOMER_NAME}" \
      --arg customer_id                "${CUSTOMER_ID}" \
      --arg account_id                 "${ACCOUNT_ID}" \
      --arg region                     "${DEPLOYMENT_REGION}" \
      --arg deployment_region          "${DEPLOYMENT_REGION}" \
      --arg idc_region                 "${EFFECTIVE_REGION}" \
      --arg partition                  "${PARTITION}" \
      --arg instance_arn               "${INSTANCE_ARN}" \
      --arg identity_store_id          "${IDSTORE_ID}" \
      --arg region_policy_id           "${REGION_POLICY_ID}" \
      --arg root_policy_id             "${ROOT_POLICY_ID}" \
      --arg ps_platform_arn            "${PS_PLATFORM_ARN}" \
      --arg ps_breakglass_arn          "${PS_BREAKGLASS_ARN}" \
      --arg pa_group_id                "${PA_GROUP_ID}" \
      --arg bg_group_id                "${BG_GROUP_ID}" \
      --arg pa_role_arn                "${PA_ROLE_ARN}" \
      --arg bg_role_arn                "${BG_ROLE_ARN}" \
      --arg deployment_role_arn        "${DEPLOYMENT_ROLE_ARN}" \
      --arg deployment_role_name       "${DEPLOYMENT_ROLE_NAME}" \
      --arg drift_reader_role_arn      "${DRIFT_READER_ROLE_ARN}" \
      --arg drift_reader_role_name     "${DRIFT_READER_ROLE_NAME}" \
      --arg customer_cmk_arn           "${CUSTOMER_CMK_ARN}" \
      --arg customer_cmk_key_id        "${CUSTOMER_CMK_KEY_ID}" \
      --arg customer_cmk_alias         "${CUSTOMER_CMK_ALIAS}" \
      --arg external_id_secret_arn     "${EXTERNAL_ID_SECRET_ARN}" \
      --arg external_id_secret_name    "${EXTERNAL_ID_SECRET_NAME}" \
      --arg state_bucket_name          "${STATE_BUCKET_NAME}" \
      --arg state_lock_table_name      "${STATE_LOCK_TABLE_NAME}" \
      --arg axelspire_ci_account_id    "${AXELSPIRE_CI_ACCOUNT_ID}" \
      --arg axelspire_ci_region        "${AXELSPIRE_CI_REGION}" \
      --arg axelspire_ci_role_name     "${AXELSPIRE_CI_ROLE_NAME}" \
      --arg axelspire_kms_arn          "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" \
      --arg axelspire_s3_arn           "${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}" \
      --arg bootstrap_version          "${BOOTSTRAP_VERSION}" \
      --arg bootstrap_variant          "${BOOTSTRAP_VARIANT}" \
      '{
        bootstrap_version: $bootstrap_version,
        bootstrap_variant: $bootstrap_variant,
        customer_name: $customer_name,
        customer_id: $customer_id,
        account_id: $account_id,
        region: $region,
        deployment_region: $deployment_region,
        idc_region: $idc_region,
        partition: $partition,
        phase0: {
          identity_center_instance_arn: $instance_arn,
          identity_store_id: $identity_store_id,
          region_deny_policy_id: $region_policy_id,
          root_user_deny_policy_id: $root_policy_id,
          platform_admin_permission_set_arn: $ps_platform_arn,
          breakglass_permission_set_arn: $ps_breakglass_arn,
          platform_admins_group_id: $pa_group_id,
          breakglass_group_id: $bg_group_id,
          platform_admin_role_arn: $pa_role_arn,
          breakglass_role_arn: $bg_role_arn,
          customer_admin_role_arns: [$pa_role_arn, $bg_role_arn] | map(select(. != ""))
        },
        phase5: {
          deployment_role_name: $deployment_role_name,
          deployment_role_arn: $deployment_role_arn,
          drift_reader_role_name: $drift_reader_role_name,
          drift_reader_role_arn: $drift_reader_role_arn,
          customer_kms_principals_ready: ($deployment_role_arn != "" and $drift_reader_role_arn != ""),
          customer_cmk_alias: $customer_cmk_alias,
          customer_cmk_key_id: $customer_cmk_key_id,
          customer_cmk_arn: $customer_cmk_arn,
          external_id_secret_name: $external_id_secret_name,
          external_id_secret_arn: $external_id_secret_arn,
          state_bucket_name: $state_bucket_name,
          state_lock_table_name: $state_lock_table_name,
          axelspire_ci_account_id: $axelspire_ci_account_id,
          axelspire_ci_region: $axelspire_ci_region,
          axelspire_ci_role_name: $axelspire_ci_role_name,
          axelspire_artifact_kms_key_arn: $axelspire_kms_arn,
          axelspire_artifact_s3_bucket_arn: $axelspire_s3_arn
        }
      }'
  else
    # jq-less fallback. Flat shape (no nested objects) to keep the
    # printf simple; consumers should prefer the jq path.
    printf '{\n'
    printf '  "bootstrap_version": "%s",\n'                   "${BOOTSTRAP_VERSION}"
    printf '  "bootstrap_variant": "%s",\n'                   "${BOOTSTRAP_VARIANT}"
    printf '  "customer_name": "%s",\n'                       "${CUSTOMER_NAME}"
    printf '  "customer_id": "%s",\n'                         "${CUSTOMER_ID}"
    printf '  "account_id": "%s",\n'                          "${ACCOUNT_ID}"
    printf '  "region": "%s",\n'                              "${DEPLOYMENT_REGION}"
    printf '  "deployment_region": "%s",\n'                   "${DEPLOYMENT_REGION}"
    printf '  "idc_region": "%s",\n'                          "${EFFECTIVE_REGION}"
    printf '  "partition": "%s",\n'                           "${PARTITION}"
    printf '  "identity_center_instance_arn": "%s",\n'        "${INSTANCE_ARN}"
    printf '  "identity_store_id": "%s",\n'                   "${IDSTORE_ID}"
    printf '  "region_deny_policy_id": "%s",\n'               "${REGION_POLICY_ID}"
    printf '  "root_user_deny_policy_id": "%s",\n'            "${ROOT_POLICY_ID}"
    printf '  "platform_admin_permission_set_arn": "%s",\n'   "${PS_PLATFORM_ARN}"
    printf '  "breakglass_permission_set_arn": "%s",\n'       "${PS_BREAKGLASS_ARN}"
    printf '  "platform_admins_group_id": "%s",\n'            "${PA_GROUP_ID}"
    printf '  "breakglass_group_id": "%s",\n'                 "${BG_GROUP_ID}"
    printf '  "platform_admin_role_arn": "%s",\n'             "${PA_ROLE_ARN}"
    printf '  "breakglass_role_arn": "%s",\n'                 "${BG_ROLE_ARN}"
    printf '  "deployment_role_arn": "%s",\n'                 "${DEPLOYMENT_ROLE_ARN}"
    printf '  "customer_cmk_arn": "%s",\n'                    "${CUSTOMER_CMK_ARN}"
    printf '  "external_id_secret_arn": "%s",\n'              "${EXTERNAL_ID_SECRET_ARN}"
    printf '  "state_bucket_name": "%s",\n'                   "${STATE_BUCKET_NAME}"
    printf '  "state_lock_table_name": "%s",\n'               "${STATE_LOCK_TABLE_NAME}"
    printf '  "axelspire_artifact_kms_key_arn": "%s",\n'      "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
    printf '  "axelspire_artifact_s3_bucket_arn": "%s"\n'     "${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}"
    printf '}\n'
  fi
}

# ---------------------------------------------------------------------------
# Sub-commands
# ---------------------------------------------------------------------------
do_preflight () { preflight; log "preflight OK"; }

do_outputs () {
  resolve_outputs
  print_outputs_human
}

do_outputs_json () {
  resolve_outputs
  print_outputs_json
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main () {
  if [ $# -eq 0 ]; then usage; exit 0; fi
  INVOCATION_ARGV=( "$@" )
  if declare -F bootstrap_maybe_self_update >/dev/null 2>&1; then
    BOOTSTRAP_SCRIPT_PATH="${BASH_SOURCE[0]}"
    bootstrap_maybe_self_update "$@"
  fi
  parse_args "$@"
  case "${COMMAND}" in
    help|--help|-h) usage; exit 0 ;;
  esac
  case "${COMMAND}" in
    apply|preflight) init_logging ;;
  esac
  case "${COMMAND}" in
    apply)        do_apply ;;
    preflight)    do_preflight ;;
    outputs)      do_outputs ;;
    outputs-json) do_outputs_json ;;
    *) usage; die "unknown command: ${COMMAND}" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi

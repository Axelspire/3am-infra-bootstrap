#!/usr/bin/env bash
# customer-org-setup.sh — one-time-per-customer-Organization setup for 3AM.
#
# Designed to run in AWS CloudShell from the customer's Org-management
# account. Idempotent: safe to re-run after a partial failure. Every
# resource is "list-then-create-if-missing"; existing resources are
# reused as-is. Re-running with the same inputs is a no-op.
#
# See ONBOARDING-FLOW.md (Phase 0) for the rationale and the manual
# fallback CLI sequence.

set -Eeuo pipefail

BOOTSTRAP_VERSION="0.2.0"
BOOTSTRAP_VARIANT="multi-account"

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
CMK_POLICY_FILE="/tmp/3am-customer-cmk-policy.json"
STATE_BUCKET_POLICY_FILE="/tmp/3am-state-bucket-policy.json"

ACCOUNT_NAME="3AM Production"
OU_NAME="3AM"
ALLOWED_REGIONS_CSV="eu-west-1,us-east-1"
PLATFORM_ADMINS_GROUP="3AM-Platform-Admins"
BREAKGLASS_GROUP="3AM-BreakGlass"
EXTERNAL_IDP=false
SKIP_SCPS=false
SKIP_BOOTSTRAP=false
AUTO_APPROVE=false
QUIET=false
LOG_DIR="${HOME}"
COMMAND="apply"

# Phase 5 defaults (operator usually leaves these alone).
AXELSPIRE_CI_ACCOUNT_ID="033113129683"
AXELSPIRE_CI_REGION="eu-west-1"
AXELSPIRE_CI_ROLE_NAME="GitHubActions-CustomerDeploy"
DEPLOYMENT_ROLE_NAME="ThreeAM-Deployment"
EXTERNAL_ID_SECRET_NAME="/3am/license/external-id"
REQUIRE_LICENSE_SESSION_TAG=true
KMS_MULTI_REGION=false
STATE_LOCK_TABLE_NAME="3am-state-lock"
CUSTOMER_CMK_ALIAS="alias/3am-customer-cmk"
ORG_ACCESS_ROLE_NAME="OrganizationAccountAccessRole"

# Per-customer inputs (no defaults — must be supplied on first apply).
CUSTOMER_NAME=""
CUSTOMER_ID=""
ACCOUNT_EMAIL=""
PLATFORM_ADMIN_USER=""
BREAKGLASS_USER=""

# Resolved at runtime by preflight / apply.
INSTANCE_ARN=""
IDSTORE_ID=""
ROOT_ID=""
OU_ID=""
ACCOUNT_ID=""
MGMT_ACCOUNT_ID=""
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

# Phase 5 outputs (populated by phase5_apply).
DEPLOYMENT_ROLE_ARN=""
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
  LOG_FILE="${LOG_DIR}/3am-org-setup-$(date -u +%Y%m%dT%H%M%SZ).log"
  # Tee stdout/stderr to the log file. CloudShell $HOME persists across
  # sessions so the operator can download the file later.
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
Usage: customer-org-setup.sh [COMMAND] [OPTIONS]

Multi-account variant of the 3AM bootstrap. Creates (or reuses) a child
AWS account under a 3AM OU, runs Phase 0 (Identity Center / SCPs) in
the management account, then auto-assumes OrganizationAccountAccessRole
into the child account to run Phase 5 (ThreeAM-Deployment role, customer
CMK, state backend, external-ID secret, SSM parameters). Emits a single
handoff JSON blob for AxelSpire.

Commands:
  apply        Run / resume the full setup (default).
  preflight    Run only the preflight checks (no AWS writes).
  outputs      Re-resolve and print outputs as human-readable text.
  outputs-json Re-resolve and print outputs as JSON (for CI/CD ingestion).
  help         Show this help.

Required on first apply (subsequent runs reuse existing resources):
  --customer-name NAME          Customer display name, e.g. "Acme Corp".
  --account-email EMAIL         Root email for the new 3AM AWS account.
  --platform-admin-user EMAIL   First member of the platform-admin group
                                (UserName in Identity Center directory).
  --breakglass-user EMAIL       First member of the break-glass group.

Optional:
  --customer-id SLUG            Lowercase slug used in resource tags and
                                the AxelSpire CI key alias. Default: a
                                slug derived from --customer-name.
  --account-name NAME           Default: "3AM Production".
  --ou-name NAME                Default: "3AM".
  --allowed-regions LIST        CSV, default: "eu-west-1,us-east-1".
  --deployment-region REGION    Customer workload region: where the
                                state bucket, DynamoDB lock table,
                                customer CMK and external-ID secret
                                live, and which the
                                --axelspire-artifact-kms-key-arn must
                                match. Default: the shell's AWS_REGION
                                (which also drives Identity Center /
                                Organizations API calls). Set this
                                explicitly when the IAM Identity Center
                                home region differs from the customer's
                                deployment region (IDC is one-per-org;
                                deployment region is per-customer).
                                Must be listed in --allowed-regions.
  --platform-admins-group NAME  Default: "3AM-Platform-Admins".
  --breakglass-group NAME       Default: "3AM-BreakGlass".
  --external-idp                Skip user/group creation; expect them
                                to come from an external IdP via SCIM.
  --skip-scps                   Do not create or attach the 3am-region-deny
                                / 3am-root-user-deny SCPs.
  --skip-bootstrap              Run Phase 0 (account, OU, SCPs, Identity
                                Center) only; skip Phase 5 inside the
                                child account.

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
  --org-access-role NAME        IAM role to assume into the child account
                                for Phase 5. Default: OrganizationAccount-
                                AccessRole.

  --auto-approve                Skip interactive confirmation.
  --log-dir PATH                Default: $HOME (CloudShell-persistent).
  --quiet                       Reduce console noise (file log is full).

Outputs commands take no per-customer flags; they re-resolve every
value from AWS using --account-name / --ou-name / group names.

Examples:
  # First run
  ./customer-org-setup.sh apply \
    --customer-name "Acme Corp" \
    --account-email aws-3am@acme.example.com \
    --platform-admin-user alice@acme.example.com \
    --breakglass-user bob@acme.example.com

  # CI ingestion later
  ./customer-org-setup.sh outputs-json > org-setup.json
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args () {
  if [[ $# -gt 0 && "$1" != --* ]]; then COMMAND="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --customer-name)             CUSTOMER_NAME="$2"; shift 2 ;;
      --customer-id)               CUSTOMER_ID="$2"; shift 2 ;;
      --account-name)              ACCOUNT_NAME="$2"; shift 2 ;;
      --account-email)             ACCOUNT_EMAIL="$2"; shift 2 ;;
      --ou-name)                   OU_NAME="$2"; shift 2 ;;
      --allowed-regions)           ALLOWED_REGIONS_CSV="$2"; shift 2 ;;
      --deployment-region)         DEPLOYMENT_REGION="$2"; shift 2 ;;
      --platform-admin-user)       PLATFORM_ADMIN_USER="$2"; shift 2 ;;
      --breakglass-user)           BREAKGLASS_USER="$2"; shift 2 ;;
      --platform-admins-group)     PLATFORM_ADMINS_GROUP="$2"; shift 2 ;;
      --breakglass-group)          BREAKGLASS_GROUP="$2"; shift 2 ;;
      --external-idp)              EXTERNAL_IDP=true; shift ;;
      --skip-scps)                 SKIP_SCPS=true; shift ;;
      --skip-bootstrap)            SKIP_BOOTSTRAP=true; shift ;;
      --axelspire-ci-account-id)   AXELSPIRE_CI_ACCOUNT_ID="$2"; shift 2 ;;
      --axelspire-ci-region)       AXELSPIRE_CI_REGION="$2"; shift 2 ;;
      --axelspire-ci-role-name)    AXELSPIRE_CI_ROLE_NAME="$2"; shift 2 ;;
      --axelspire-artifact-kms-key-arn)    AXELSPIRE_ARTIFACT_KMS_KEY_ARN="$2"; shift 2 ;;
      --axelspire-artifact-s3-bucket-arn)  AXELSPIRE_ARTIFACT_S3_BUCKET_ARN="$2"; shift 2 ;;
      --external-id-secret-name)   EXTERNAL_ID_SECRET_NAME="$2"; shift 2 ;;
      --no-license-session-tag)    REQUIRE_LICENSE_SESSION_TAG=false; shift ;;
      --kms-multi-region)          KMS_MULTI_REGION=true; shift ;;
      --org-access-role)           ORG_ACCESS_ROLE_NAME="$2"; shift 2 ;;
      --auto-approve)              AUTO_APPROVE=true; shift ;;
      --log-dir)                   LOG_DIR="$2"; shift 2 ;;
      --quiet)                     QUIET=true; shift ;;
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
  MGMT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  [ -n "$MGMT_ACCOUNT_ID" ] && [ "$MGMT_ACCOUNT_ID" != "None" ] || die "could not resolve caller account ID"
  PARTITION=$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)
  [ -n "$PARTITION" ] || PARTITION="aws"
  log "preflight: management account = ${MGMT_ACCOUNT_ID} (partition ${PARTITION})"

  EFFECTIVE_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
  [ -n "$EFFECTIVE_REGION" ] || EFFECTIVE_REGION="<unset>"
  log "preflight: effective region = ${EFFECTIVE_REGION} (Identity Center / Organizations APIs target this region)"

  # DEPLOYMENT_REGION drives the customer workload: state bucket, lock
  # table, customer CMK, external-ID secret, kms:ViaService in the CMK
  # policy, and the region match for --axelspire-artifact-kms-key-arn.
  # Defaults to EFFECTIVE_REGION (current behavior); set explicitly when
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

  log "preflight: organization feature set"
  local fs mgmt
  fs=$(aws organizations describe-organization \
        --query 'Organization.FeatureSet' --output text 2>/dev/null) || \
    die "not logged into an Org-management account (or not part of an Organization)"
  [ "$fs" = "ALL" ] || die "Organization is in '${fs}' mode; ALL features required for SCPs"

  mgmt=$(aws organizations describe-organization \
          --query 'Organization.MasterAccountId' --output text)
  [ "$mgmt" = "$MGMT_ACCOUNT_ID" ] || die "caller account ${MGMT_ACCOUNT_ID} is not the Org management account (${mgmt}). customer-org-setup.sh must run in the management account."

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

  log "preflight: ensure SCP and TAG policy types enabled on root (idempotent)"
  aws organizations enable-policy-type --root-id "${ROOT_ID}" \
    --policy-type SERVICE_CONTROL_POLICY >/dev/null 2>&1 || true
  aws organizations enable-policy-type --root-id "${ROOT_ID}" \
    --policy-type TAG_POLICY >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Idempotent helpers — each prints the resolved ID/ARN on stdout; chatter
# goes to stderr via log/warn.
# ---------------------------------------------------------------------------
get_or_create_ou () {
  local name=$1 parent=$2 id
  id=$(aws organizations list-organizational-units-for-parent \
        --parent-id "${parent}" \
        --query "OrganizationalUnits[?Name==\`${name}\`].Id | [0]" \
        --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    log "creating OU '${name}' under ${parent}" >&2
    id=$(aws organizations create-organizational-unit \
          --parent-id "${parent}" --name "${name}" \
          --query 'OrganizationalUnit.Id' --output text)
  else
    log "reusing OU '${name}' = ${id}" >&2
  fi
  echo "$id"
}

get_or_create_account () {
  local name=$1 email=$2 id
  id=$(aws organizations list-accounts \
        --query "Accounts[?Name==\`${name}\`].Id | [0]" --output text)
  if [ "$id" != "None" ] && [ -n "$id" ]; then
    log "reusing account '${name}' = ${id}" >&2
    echo "$id"; return
  fi
  log "creating account '${name}' <${email}>" >&2
  local req_id state
  req_id=$(aws organizations create-account \
            --account-name "${name}" --email "${email}" \
            --role-name OrganizationAccountAccessRole \
            --iam-user-access-to-billing DENY \
            --query 'CreateAccountStatus.Id' --output text)
  log "polling create-account ${req_id} (can take up to ~1 hour)" >&2
  local i=0
  while : ; do
    state=$(aws organizations describe-create-account-status \
              --create-account-request-id "${req_id}" \
              --query 'CreateAccountStatus.State' --output text)
    case "$state" in
      SUCCEEDED) break ;;
      FAILED)
        local reason
        reason=$(aws organizations describe-create-account-status \
                  --create-account-request-id "${req_id}" \
                  --query 'CreateAccountStatus.FailureReason' --output text)
        die "account creation failed: ${reason}"
        ;;
    esac
    i=$((i+1))
    [ $((i % 6)) -eq 0 ] && log "  …still ${state} after $((i*10))s" >&2
    sleep 10
  done
  id=$(aws organizations describe-create-account-status \
        --create-account-request-id "${req_id}" \
        --query 'CreateAccountStatus.AccountId' --output text)
  log "created account ${id}" >&2
  echo "$id"
}

move_account_if_needed () {
  local account=$1 target_parent=$2 current
  current=$(aws organizations list-parents --child-id "${account}" \
             --query 'Parents[0].Id' --output text)
  if [ "$current" = "$target_parent" ]; then
    log "account ${account} already in ${target_parent}" >&2
    return
  fi
  log "moving ${account}: ${current} -> ${target_parent}" >&2
  aws organizations move-account \
    --account-id "${account}" \
    --source-parent-id "${current}" \
    --destination-parent-id "${target_parent}"
}

get_or_create_scp () {
  local name=$1 file=$2 id
  [ -f "$file" ] || die "policy file not found: ${file}"
  id=$(aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
        --query "Policies[?Name==\`${name}\`].Id | [0]" --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    log "creating SCP '${name}' from ${file}" >&2
    id=$(aws organizations create-policy \
          --name "${name}" --type SERVICE_CONTROL_POLICY \
          --description "managed by customer-org-setup.sh" \
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
  description="3AM ${name} (managed by customer-org-setup.sh)"
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
          --description "3AM (managed by customer-org-setup.sh)" \
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
  # Best-effort name split: local-part is "given.family" or just given.
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

# AWSReservedSSO_<PermissionSet>_<hash> role only exists in the target
# account once the assignment is SUCCEEDED. Resolve via OrganizationAccountAccessRole.
resolve_reserved_sso_role_arn () {
  local account=$1 ps_name=$2 creds role_arn
  creds=$(aws sts assume-role \
          --role-arn "arn:aws:iam::${account}:role/OrganizationAccountAccessRole" \
          --role-session-name "org-setup-resolve-role" \
          --duration-seconds 900 \
          --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
          --output text 2>/dev/null) || { echo ""; return; }
  read -r AKI SAK STK <<<"${creds}"
  role_arn=$(AWS_ACCESS_KEY_ID="${AKI}" AWS_SECRET_ACCESS_KEY="${SAK}" AWS_SESSION_TOKEN="${STK}" \
             aws iam list-roles \
               --path-prefix /aws-reserved/sso.amazonaws.com/ \
               --query "Roles[?starts_with(RoleName, \`AWSReservedSSO_${ps_name}_\`)].Arn | [0]" \
               --output text 2>/dev/null || echo None)
  [ "$role_arn" = "None" ] && role_arn=""
  echo "$role_arn"
}


# ---------------------------------------------------------------------------
# Policy file generation
# ---------------------------------------------------------------------------
# SCP bodies are embedded here so the script is fully self-contained
# (single `curl` deployment). Files are (re)written on every apply —
# any local edits are discarded. The `allowed_regions` SCP picks up
# whatever was passed in --allowed-regions.
write_policy_files () {
  local regions_json
  # Convert "eu-west-1,us-east-1" -> "\"eu-west-1\", \"us-east-1\""
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
  # Validate the JSON we just wrote so a malformed heredoc fails fast
  # instead of being rejected by AWS with MalformedPolicyDocumentException.
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool < "${REGION_POLICY_FILE}" > /dev/null || die "generated ${REGION_POLICY_FILE} is not valid JSON"
    python3 -m json.tool < "${ROOT_POLICY_FILE}"   > /dev/null || die "generated ${ROOT_POLICY_FILE} is not valid JSON"
  fi
}

# ---------------------------------------------------------------------------
# Phase 5 — slug derivation, deterministic AxelSpire ARNs, assume-role.
# ---------------------------------------------------------------------------
# Derive a lowercase, hyphen-delimited slug for CUSTOMER_ID when the
# operator did not pass --customer-id. Called after preflight so the
# error message can reference the supplied --customer-name.
resolve_customer_id () {
  if [ -z "$CUSTOMER_ID" ]; then
    CUSTOMER_ID=$(printf '%s' "${CUSTOMER_NAME}" \
                    | tr '[:upper:]' '[:lower:]' \
                    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    [ -n "$CUSTOMER_ID" ] || die "could not derive --customer-id from --customer-name '${CUSTOMER_NAME}'; pass --customer-id explicitly"
    log "auto-derived --customer-id from --customer-name: ${CUSTOMER_ID}"
  fi
  echo "${CUSTOMER_ID}" | grep -qE '^[a-z0-9-]+$' || die "--customer-id '${CUSTOMER_ID}' must be lowercase alphanumeric with hyphens only"
}

# Derive the AxelSpire-side ARNs. The S3 bucket ARN follows a
# deterministic naming convention. The KMS value must be the customer-
# region MRK replica's key-ID ARN: alias ARNs do not authorize IAM
# Resource matching, and DynamoDB CreateTable requires a same-region
# customer-managed key.
phase5_validate_axelspire_kms_arn () {
  # Strict validation runs only on apply: outputs / outputs-json paths
  # may recover the ARN from SSM after assuming into the child account
  # (see resolve_outputs), so an empty value at this point is not fatal.
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

# Persist customer_id / customer_name / deployment_region as tags on the
# child AWS account so a later 'outputs' / 'outputs-json' invocation in a
# fresh shell can recover them without operator-supplied flags.
# Idempotent (TagResource overwrites existing values). Best-effort: warns
# rather than dies on failure, since losing the persistence layer does
# not affect the current apply.
tag_child_account_with_customer_metadata () {
  [ -n "${ACCOUNT_ID}" ] && [ "${ACCOUNT_ID}" != "None" ] \
    || { warn "tag_child_account: ACCOUNT_ID not set; skipping"; return 0; }
  [ -n "${CUSTOMER_ID}" ] \
    || { warn "tag_child_account: CUSTOMER_ID not set; skipping"; return 0; }
  log "tagging account ${ACCOUNT_ID} with CustomerId=${CUSTOMER_ID} DeploymentRegion=${DEPLOYMENT_REGION}"
  aws organizations tag-resource --resource-id "${ACCOUNT_ID}" --tags \
    "Key=CustomerId,Value=${CUSTOMER_ID}" \
    "Key=CustomerName,Value=${CUSTOMER_NAME}" \
    "Key=DeploymentRegion,Value=${DEPLOYMENT_REGION}" \
    "Key=ManagedBy,Value=customer-org-setup.sh" \
    "Key=BootstrapVersion,Value=${BOOTSTRAP_VERSION}" \
    >/dev/null 2>&1 \
    || warn "tag_child_account: organizations:TagResource failed (need organizations:TagResource permission). Slug will still appear in this run's JSON, but later 'outputs-json' invocations will not be able to recover it."
}

# Saved management-account credentials. assume_workload_creds stashes
# whatever was in the environment (typically nothing in CloudShell —
# the SDK reads CloudShell's container role from IMDS) so that
# restore_mgmt_creds can put it back.
_SAVED_AWS_ACCESS_KEY_ID=""
_SAVED_AWS_SECRET_ACCESS_KEY=""
_SAVED_AWS_SESSION_TOKEN=""
_SAVED_AWS_REGION=""
_SAVED_AWS_REGION_SET=false
_HAVE_ASSUMED=false

assume_workload_creds () {
  local account=$1 role=${2:-${ORG_ACCESS_ROLE_NAME}} creds
  log "assuming arn:${PARTITION}:iam::${account}:role/${role} (session 'org-setup-phase5')"
  creds=$(aws sts assume-role \
            --role-arn "arn:${PARTITION}:iam::${account}:role/${role}" \
            --role-session-name "org-setup-phase5" \
            --duration-seconds 3600 \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
            --output text) || die "could not assume ${role} into ${account}; ensure the role exists (it is created automatically when the account is created via Organizations) and that the management caller has sts:AssumeRole on it"
  _SAVED_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
  _SAVED_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
  _SAVED_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
  # Save AWS_REGION and pivot to DEPLOYMENT_REGION for child-account work
  # (state bucket, lock table, customer CMK, secrets, SSM all live there).
  # _SAVED_AWS_REGION_SET tracks whether AWS_REGION was exported at all,
  # so restore_mgmt_creds can distinguish "was empty" from "was unset".
  if [ -n "${AWS_REGION+x}" ]; then
    _SAVED_AWS_REGION="${AWS_REGION}"
    _SAVED_AWS_REGION_SET=true
  else
    _SAVED_AWS_REGION=""
    _SAVED_AWS_REGION_SET=false
  fi
  read -r AKI SAK STK <<<"${creds}"
  export AWS_ACCESS_KEY_ID="${AKI}"
  export AWS_SECRET_ACCESS_KEY="${SAK}"
  export AWS_SESSION_TOKEN="${STK}"
  if [ -n "${DEPLOYMENT_REGION}" ] && [ "${DEPLOYMENT_REGION}" != "<unset>" ]; then
    export AWS_REGION="${DEPLOYMENT_REGION}"
    log "child-account AWS_REGION pinned to ${DEPLOYMENT_REGION} (deployment region)"
  fi
  _HAVE_ASSUMED=true
  # Confirm the assume worked.
  local who
  who=$(aws sts get-caller-identity --query Account --output text)
  [ "$who" = "$account" ] || die "assumed role identity (${who}) does not match expected child account (${account})"
  log "now operating as account ${account} (assumed)"
}

restore_mgmt_creds () {
  ${_HAVE_ASSUMED} || return 0
  if [ -n "${_SAVED_AWS_ACCESS_KEY_ID}" ]; then
    export AWS_ACCESS_KEY_ID="${_SAVED_AWS_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${_SAVED_AWS_SECRET_ACCESS_KEY}"
    export AWS_SESSION_TOKEN="${_SAVED_AWS_SESSION_TOKEN}"
  else
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  fi
  if ${_SAVED_AWS_REGION_SET}; then
    export AWS_REGION="${_SAVED_AWS_REGION}"
  else
    unset AWS_REGION
  fi
  _HAVE_ASSUMED=false
  local who
  who=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  log "restored management-account credentials (now operating as ${who})"
}

# ---------------------------------------------------------------------------
# Phase 5 — policy file generation (rewritten on every apply).
# ---------------------------------------------------------------------------
# Mirrors deploy/iam.tf, deploy/iam-permissions-ec2.tf,
# deploy/iam-permissions-extra.tf, deploy/kms.tf and deploy/state-backend.tf.
phase5_write_policy_files () {
  local external_id="${1:-}" admin_arns_json="${2:-[]}"
  log "writing ${TRUST_POLICY_FILE}"
  # Trust policy is split into two statements. sts:RoleSessionName and
  # sts:ExternalId are not valid context keys for sts:TagSession, so a
  # single combined statement would fail the condition check on every
  # TagSession call from a 3am-* session. The AssumeRole statement
  # carries the session-name / external-id gates; the TagSession
  # statement carries only the aws:RequestTag/LicenseValid gate.
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
          } + (if ($tag_conds | length) > 0 then {Condition: $tag_conds} else {} end))
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
      "Action": ["ec2:DescribeVpcs","ec2:DescribeSubnets","ec2:DescribeRouteTables",
                 "ec2:DescribeNetworkInterfaces","ec2:DescribeSecurityGroups",
                 "ec2:DescribeAvailabilityZones","ec2:DescribeRegions","ec2:DescribeAccountAttributes"],
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
    { "Sid": "SsmReadOn3amParameters", "Effect": "Allow",
      "Action": ["ssm:GetParameter","ssm:GetParameters","ssm:GetParametersByPath","ssm:DescribeParameters"],
      "Resource": ["arn:${PARTITION}:ssm:*:${ACCOUNT_ID}:parameter/3am/*"] },
    { "Sid": "SsmWriteOn3amParameters", "Effect": "Allow",
      "Action": ["ssm:PutParameter","ssm:DeleteParameter","ssm:DeleteParameters",
                 "ssm:AddTagsToResource","ssm:RemoveTagsFromResource","ssm:LabelParameterVersion"],
      "Resource": ["arn:${PARTITION}:ssm:*:${ACCOUNT_ID}:parameter/3am/*"] },
    { "Sid": "LogsOn3amGroups", "Effect": "Allow",
      "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:DeleteLogGroup",
                 "logs:DescribeLogGroups","logs:DescribeLogStreams","logs:PutLogEvents",
                 "logs:PutRetentionPolicy","logs:TagResource","logs:UntagResource","logs:AssociateKmsKey"],
      "Resource": ["arn:${PARTITION}:logs:*:${ACCOUNT_ID}:log-group:/aws/lambda/3am-*",
                   "arn:${PARTITION}:logs:*:${ACCOUNT_ID}:log-group:/aws/lambda/3am-*:*",
                   "arn:${PARTITION}:logs:*:${ACCOUNT_ID}:log-group:/3am/*",
                   "arn:${PARTITION}:logs:*:${ACCOUNT_ID}:log-group:/3am/*:*"] },
    { "Sid": "ApiGatewayOnTaggedResources", "Effect": "Allow",
      "Action": ["apigateway:GET","apigateway:POST","apigateway:PUT","apigateway:PATCH",
                 "apigateway:DELETE","apigateway:TagResource","apigateway:UntagResource"],
      "Resource": ["arn:${PARTITION}:apigateway:*::/*"],
      "Condition": { "StringEquals": { "aws:ResourceTag/Service": "3am" } } },
    { "Sid": "Route53Read", "Effect": "Allow",
      "Action": ["route53:ListHostedZones","route53:GetHostedZone",
                 "route53:ListResourceRecordSets","route53:GetChange"],
      "Resource": ["*"] },
    { "Sid": "Route53WriteOnTaggedZones", "Effect": "Allow",
      "Action": ["route53:ChangeResourceRecordSets","route53:ChangeTagsForResource"],
      "Resource": ["arn:${PARTITION}:route53:::hostedzone/*"],
      "Condition": { "StringEquals": { "aws:ResourceTag/3am-managed": "true" } } },
    { "Sid": "AcmOnTaggedCertificates", "Effect": "Allow",
      "Action": ["acm:DescribeCertificate","acm:GetCertificate","acm:ListTagsForCertificate",
                 "acm:DeleteCertificate","acm:AddTagsToCertificate","acm:RemoveTagsFromCertificate"],
      "Resource": ["*"],
      "Condition": { "StringEquals": { "aws:ResourceTag/Service": "3am" } } },
    { "Sid": "AcmListAndRequest", "Effect": "Allow",
      "Action": ["acm:ListCertificates","acm:RequestCertificate"], "Resource": ["*"] }
  ]
}
EOF

  log "writing ${CMK_POLICY_FILE}"
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

  if command -v python3 >/dev/null 2>&1; then
    local f
    for f in "${TRUST_POLICY_FILE}" "${PERMS_POLICY_FILE}" "${PERMS_EC2_FILE}" \
             "${PERMS_EXTRA_FILE}" "${CMK_POLICY_FILE}" "${STATE_BUCKET_POLICY_FILE}"; do
      python3 -m json.tool < "${f}" > /dev/null || die "generated ${f} is not valid JSON"
    done
  fi
}

# ---------------------------------------------------------------------------
# Phase 5 — idempotent resource helpers (run in the assumed child-account
# credential context).
# ---------------------------------------------------------------------------
phase5_common_tags_cli () {
  echo "Key=Service,Value=3am Key=CustomerId,Value=${CUSTOMER_ID} Key=ManagedBy,Value=customer-org-setup.sh Key=BootstrapVersion,Value=${BOOTSTRAP_VERSION}"
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
          --tags $(phase5_common_tags_cli) \
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
  if aws s3api head-bucket --bucket "${STATE_BUCKET_NAME}" 2>/dev/null; then
    log "reusing state bucket ${STATE_BUCKET_NAME}"
  else
    log "creating state bucket ${STATE_BUCKET_NAME}"
    if [ "${DEPLOYMENT_REGION}" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "${STATE_BUCKET_NAME}" >/dev/null
    else
      aws s3api create-bucket --bucket "${STATE_BUCKET_NAME}" \
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
    --tagging "TagSet=[{Key=Service,Value=3am},{Key=CustomerId,Value=${CUSTOMER_ID}},{Key=ManagedBy,Value=customer-org-setup.sh},{Key=BootstrapVersion,Value=${BOOTSTRAP_VERSION}}]" >/dev/null
}

phase5_get_or_create_lock_table () {
  # The lock table holds only Terraform lock IDs and digests (no state
  # contents), so encrypting it under the customer CMK is sufficient and
  # avoids requiring the bootstrap caller (OrganizationAccountAccessRole)
  # to be authorized on the AxelSpire CI CMK. State objects in S3 remain
  # encrypted under AXELSPIRE_ARTIFACT_KMS_KEY_ARN, which is what carries
  # the "destroy-key-to-revoke-state" property.
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
             "Key=ManagedBy,Value=customer-org-setup.sh" \
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
    local name=$1 desc=$2 value=$3
    aws ssm put-parameter --name "${name}" --description "${desc}" \
      --type String --overwrite --value "${value}" >/dev/null
  }
  _put_ssm /3am/kms/customer-cmk-arn  "ARN of the customer-managed CMK."  "${CUSTOMER_CMK_ARN}"
  _put_ssm /3am/kms/customer-cmk-id   "Key ID of the customer-managed CMK." "${CUSTOMER_CMK_KEY_ID}"
  _put_ssm /3am/state/bucket-name     "Name of the S3 bucket holding Terraform state." "${STATE_BUCKET_NAME}"
  _put_ssm /3am/state/lock-table-name "Name of the DynamoDB state-lock table." "${STATE_LOCK_TABLE_NAME}"
  _put_ssm /3am/iam/deployment-role-arn "ARN of the ${DEPLOYMENT_ROLE_NAME} role." "${DEPLOYMENT_ROLE_ARN}"
  _put_ssm /3am/axelspire/artifact-kms-key-arn   "Key-ID ARN of the customer-region MRK replica of the AxelSpire-owned CI CMK." "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
  _put_ssm /3am/axelspire/artifact-s3-bucket-arn "ARN of the AxelSpire CI artifacts S3 bucket." "${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}"
  _put_ssm /3am/bootstrap/version     "Version of the bootstrap that was last applied." "${BOOTSTRAP_VERSION}"
  _put_ssm /3am/bootstrap/applied-at  "Timestamp of the last apply of the bootstrap." "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Main Phase 5 entry-point. Assumes OrganizationAccountAccessRole into
# ACCOUNT_ID for the duration of the call. PA_ROLE_ARN / BG_ROLE_ARN are
# already populated by do_apply via resolve_reserved_sso_role_arn (run
# from the management account; the function does its own assume-role
# for that lookup). Falls back to an empty CMK admin statement when
# either ARN is missing — matches deploy/kms.tf's dynamic block.
phase5_apply () {
  phase5_compute_axelspire_arns
  log "Phase 5: AxelSpire artifact KMS key = ${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"
  log "Phase 5: AxelSpire artifact S3 bucket = ${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN}"

  STATE_BUCKET_NAME="3am-state-${ACCOUNT_ID}-${DEPLOYMENT_REGION}"
  DEPLOYMENT_ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT_ID}:role/${DEPLOYMENT_ROLE_NAME}"

  local admin_arns_json="[]"
  if command -v jq >/dev/null 2>&1; then
    admin_arns_json=$(jq -nc \
      --arg pa "${PA_ROLE_ARN}" --arg bg "${BG_ROLE_ARN}" \
      '[$pa,$bg] | map(select(. != ""))')
  else
    local pa_csv="" bg_csv=""
    [ -n "${PA_ROLE_ARN}" ] && pa_csv="\"${PA_ROLE_ARN}\""
    [ -n "${BG_ROLE_ARN}" ] && bg_csv="\"${BG_ROLE_ARN}\""
    if [ -n "${pa_csv}" ] && [ -n "${bg_csv}" ]; then
      admin_arns_json="[${pa_csv},${bg_csv}]"
    elif [ -n "${pa_csv}${bg_csv}" ]; then
      admin_arns_json="[${pa_csv}${bg_csv}]"
    fi
  fi

  # Assume into the child account for the remainder of Phase 5.
  assume_workload_creds "${ACCOUNT_ID}" "${ORG_ACCESS_ROLE_NAME}"
  # On any error from here on, restore the management creds before exiting.
  trap 'restore_mgmt_creds; echo; echo "FAILED at line ${LINENO} (exit $?). Log: ${LOG_FILE:-<n/a>}" >&2' ERR

  log "== Phase 5 step 1/6: customer CMK =="
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
                     "TagKey=ManagedBy,TagValue=customer-org-setup.sh" \
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
  phase5_write_policy_files "${external_id_value}" "${admin_arns_json}"
  phase5_get_or_create_deployment_role
  phase5_put_role_inline_policies

  log "== Phase 5 step 4/6: CMK key policy (now that role exists) =="
  phase5_write_policy_files "${external_id_value}" "${admin_arns_json}"
  phase5_put_cmk_policy

  log "== Phase 5 step 5/6: state bucket + lock table =="
  phase5_get_or_create_state_bucket
  phase5_get_or_create_lock_table

  log "== Phase 5 step 6/6: SSM parameters =="
  phase5_put_ssm_params

  # Return to the management account context so any subsequent
  # work (output resolution etc.) hits the right APIs.
  restore_mgmt_creds
  trap 'echo; echo "FAILED at line ${LINENO} (exit $?). Log: ${LOG_FILE:-<n/a>}" >&2' ERR
}



# ---------------------------------------------------------------------------
# apply — full setup, idempotent
# ---------------------------------------------------------------------------
do_apply () {
  [ -n "$CUSTOMER_NAME" ]       || die "--customer-name required"
  [ -n "$ACCOUNT_EMAIL" ]       || die "--account-email required"
  if ! ${EXTERNAL_IDP}; then
    [ -n "$PLATFORM_ADMIN_USER" ] || die "--platform-admin-user required (or pass --external-idp)"
    [ -n "$BREAKGLASS_USER" ]     || die "--breakglass-user required (or pass --external-idp)"
  fi
  # --axelspire-artifact-kms-key-arn is required on apply (key-ID ARN of
  # the customer-region MRK replica; see phase5_validate_axelspire_kms_arn).

  preflight
  resolve_customer_id
  phase5_compute_axelspire_arns

  say
  say "Customer:           ${CUSTOMER_NAME}"
  say "Customer ID slug:   ${CUSTOMER_ID}"
  say "AWS account:        ${ACCOUNT_NAME} <${ACCOUNT_EMAIL}>"
  say "Parent OU:          ${OU_NAME}"
  say "Effective region:   ${EFFECTIVE_REGION} (IDC / Organizations)"
  say "Deployment region:  ${DEPLOYMENT_REGION} (state bucket, lock table, CMK)"
  say "Allowed regions:    ${ALLOWED_REGIONS_CSV}"
  say "Identity Center:    ${INSTANCE_ARN}"
  say "External IdP:       ${EXTERNAL_IDP}"
  say "Skip SCPs:          ${SKIP_SCPS}"
  say "Skip Phase 5:       ${SKIP_BOOTSTRAP}"
  say "AxelSpire CI acct:  ${AXELSPIRE_CI_ACCOUNT_ID} (${AXELSPIRE_CI_REGION})"
  say "Org access role:    ${ORG_ACCESS_ROLE_NAME} (assumed for Phase 5)"
  say
  if ! ${AUTO_APPROVE}; then
    read -r -p "Proceed? [y/N] " ans
    [ "${ans:-}" = "y" ] || die "aborted by operator"
  fi

  log "== Phase 0 step 1/6: OU =="
  OU_ID=$(get_or_create_ou "${OU_NAME}" "${ROOT_ID}")

  log "== Phase 0 step 2/6: AWS account =="
  ACCOUNT_ID=$(get_or_create_account "${ACCOUNT_NAME}" "${ACCOUNT_EMAIL}")
  move_account_if_needed "${ACCOUNT_ID}" "${OU_ID}"
  tag_child_account_with_customer_metadata

  if ${SKIP_SCPS}; then
    log "== Phase 0 step 3/6: SCPs (skipped, --skip-scps) =="
  else
    log "== Phase 0 step 3/6: SCPs =="
    write_policy_files
    REGION_POLICY_ID=$(get_or_create_scp 3am-region-deny    "${REGION_POLICY_FILE}")
    ROOT_POLICY_ID=$(get_or_create_scp   3am-root-user-deny "${ROOT_POLICY_FILE}")
    attach_policy_if_missing "${REGION_POLICY_ID}" "${OU_ID}"
    attach_policy_if_missing "${ROOT_POLICY_ID}"   "${OU_ID}"
  fi

  log "== Phase 0 step 4/6: permission sets =="
  PS_PLATFORM_ARN=$(get_or_create_permission_set PlatformAdmin PT8H)
  PS_BREAKGLASS_ARN=$(get_or_create_permission_set BreakGlass  PT1H)
  attach_managed_policy_if_missing "${PS_PLATFORM_ARN}"   arn:aws:iam::aws:policy/AdministratorAccess
  attach_managed_policy_if_missing "${PS_BREAKGLASS_ARN}" arn:aws:iam::aws:policy/AdministratorAccess

  log "== Phase 0 step 5/6: groups / users =="
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

  log "== Phase 0 step 6/6: account assignments =="
  ensure_account_assignment "${ACCOUNT_ID}" "${PS_PLATFORM_ARN}"   GROUP "${PA_GROUP_ID}"
  ensure_account_assignment "${ACCOUNT_ID}" "${PS_BREAKGLASS_ARN}" GROUP "${BG_GROUP_ID}"

  log "== resolving AWSReservedSSO role ARNs (best-effort) =="
  PA_ROLE_ARN=$(resolve_reserved_sso_role_arn "${ACCOUNT_ID}" PlatformAdmin || true)
  BG_ROLE_ARN=$(resolve_reserved_sso_role_arn "${ACCOUNT_ID}" BreakGlass    || true)

  if ${SKIP_BOOTSTRAP}; then
    log "== Phase 5 skipped (--skip-bootstrap) =="
  else
    # Phase 5 — assumes ${ORG_ACCESS_ROLE_NAME} into the child account
    # and creates the cross-account role, customer CMK, state backend,
    # external-ID secret and SSM parameters. PA_ROLE_ARN / BG_ROLE_ARN
    # may still be empty when the SSO assignment hasn't provisioned the
    # IAM-Identity-Center reserved roles yet; the CMK admin statement is
    # omitted in that case (same shape as deploy/kms.tf's dynamic block).
    phase5_apply
  fi

  print_outputs_human
  print_outputs_json > "${LOG_DIR}/3am-org-setup-outputs.json"
  log "outputs JSON: ${LOG_DIR}/3am-org-setup-outputs.json"
  log "DONE."
}

# ---------------------------------------------------------------------------
# outputs — re-resolve everything from AWS so the command works in a
# fresh shell with no in-memory state. Uses the names supplied via flags
# (or defaults) to look things up.
# ---------------------------------------------------------------------------
resolve_outputs () {
  MGMT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  PARTITION=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null | cut -d: -f2)
  [ -n "$PARTITION" ] || PARTITION="aws"
  EFFECTIVE_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"

  ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text 2>/dev/null || echo "")
  INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text 2>/dev/null || echo "")
  IDSTORE_ID=$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text 2>/dev/null || echo "")

  OU_ID=$(aws organizations list-organizational-units-for-parent \
           --parent-id "${ROOT_ID}" \
           --query "OrganizationalUnits[?Name==\`${OU_NAME}\`].Id | [0]" \
           --output text 2>/dev/null || echo "")
  ACCOUNT_ID=$(aws organizations list-accounts \
                --query "Accounts[?Name==\`${ACCOUNT_NAME}\`].Id | [0]" \
                --output text 2>/dev/null || echo "")

  # Recover customer_id / customer_name / deployment_region from the
  # child-account tags written by tag_child_account_with_customer_metadata
  # during apply, so a fresh shell can run 'outputs' / 'outputs-json'
  # without any --customer-* or --deployment-region flags.
  if [ -n "${ACCOUNT_ID}" ] && [ "${ACCOUNT_ID}" != "None" ]; then
    if [ -z "${CUSTOMER_ID}" ]; then
      CUSTOMER_ID=$(aws organizations list-tags-for-resource --resource-id "${ACCOUNT_ID}" \
                      --query "Tags[?Key=='CustomerId'].Value | [0]" --output text 2>/dev/null || echo "")
      [ "${CUSTOMER_ID}" = "None" ] && CUSTOMER_ID=""
    fi
    if [ -z "${CUSTOMER_NAME}" ]; then
      CUSTOMER_NAME=$(aws organizations list-tags-for-resource --resource-id "${ACCOUNT_ID}" \
                       --query "Tags[?Key=='CustomerName'].Value | [0]" --output text 2>/dev/null || echo "")
      [ "${CUSTOMER_NAME}" = "None" ] && CUSTOMER_NAME=""
    fi
    if [ -z "${DEPLOYMENT_REGION}" ]; then
      DEPLOYMENT_REGION=$(aws organizations list-tags-for-resource --resource-id "${ACCOUNT_ID}" \
                           --query "Tags[?Key=='DeploymentRegion'].Value | [0]" --output text 2>/dev/null || echo "")
      [ "${DEPLOYMENT_REGION}" = "None" ] && DEPLOYMENT_REGION=""
    fi
  fi
  # Final fallback: if the account tag is missing (older bootstrap or
  # tag write failed), default to the operator's effective region so
  # outputs still work in the common case where both are equal.
  [ -n "${DEPLOYMENT_REGION}" ] || DEPLOYMENT_REGION="${EFFECTIVE_REGION}"

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

  if [ -n "${ACCOUNT_ID}" ] && [ "${ACCOUNT_ID}" != "None" ]; then
    PA_ROLE_ARN=$(resolve_reserved_sso_role_arn "${ACCOUNT_ID}" PlatformAdmin || true)
    BG_ROLE_ARN=$(resolve_reserved_sso_role_arn "${ACCOUNT_ID}" BreakGlass    || true)
  fi

  # Phase 5 outputs — re-resolve from inside the child account so this
  # works from a fresh shell. Skipped if the child account couldn't be
  # found (Phase 0 not yet applied) or the assume fails (e.g. caller has
  # no sts:AssumeRole on OrganizationAccountAccessRole anymore).
  if [ -z "$CUSTOMER_ID" ] && [ -n "$CUSTOMER_NAME" ]; then
    CUSTOMER_ID=$(printf '%s' "${CUSTOMER_NAME}" \
                    | tr '[:upper:]' '[:lower:]' \
                    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  fi
  [ -n "$CUSTOMER_ID" ] && phase5_compute_axelspire_arns

  if [ -n "${ACCOUNT_ID}" ] && [ "${ACCOUNT_ID}" != "None" ] && [ -n "${PARTITION}" ]; then
    # Quiet try: assume-role directly here rather than via the
    # phase5_apply helper, which die()s on failure.
    local creds=""
    creds=$(aws sts assume-role \
              --role-arn "arn:${PARTITION}:iam::${ACCOUNT_ID}:role/${ORG_ACCESS_ROLE_NAME}" \
              --role-session-name "org-setup-outputs" \
              --duration-seconds 900 \
              --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
              --output text 2>/dev/null) || creds=""
    if [ -n "${creds}" ]; then
      _SAVED_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
      _SAVED_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
      _SAVED_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
      if [ -n "${AWS_REGION+x}" ]; then
        _SAVED_AWS_REGION="${AWS_REGION}"; _SAVED_AWS_REGION_SET=true
      else
        _SAVED_AWS_REGION=""; _SAVED_AWS_REGION_SET=false
      fi
      read -r AKI SAK STK <<<"${creds}"
      export AWS_ACCESS_KEY_ID="${AKI}"
      export AWS_SECRET_ACCESS_KEY="${SAK}"
      export AWS_SESSION_TOKEN="${STK}"
      # Same rationale as assume_workload_creds: customer KMS/Secrets/SSM
      # live in DEPLOYMENT_REGION, not in the IDC home region.
      if [ -n "${DEPLOYMENT_REGION}" ] && [ "${DEPLOYMENT_REGION}" != "<unset>" ]; then
        export AWS_REGION="${DEPLOYMENT_REGION}"
      fi
      _HAVE_ASSUMED=true

      DEPLOYMENT_ROLE_ARN=$(aws iam get-role --role-name "${DEPLOYMENT_ROLE_NAME}" \
                              --query 'Role.Arn' --output text 2>/dev/null || echo "")
      CUSTOMER_CMK_KEY_ID=$(aws kms describe-key --key-id "${CUSTOMER_CMK_ALIAS}" \
                              --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo "")
      if [ -n "$CUSTOMER_CMK_KEY_ID" ] && [ "$CUSTOMER_CMK_KEY_ID" != "None" ]; then
        CUSTOMER_CMK_ARN=$(aws kms describe-key --key-id "${CUSTOMER_CMK_KEY_ID}" \
                             --query 'KeyMetadata.Arn' --output text 2>/dev/null || echo "")
      fi
      EXTERNAL_ID_SECRET_ARN=$(aws secretsmanager describe-secret \
                                --secret-id "${EXTERNAL_ID_SECRET_NAME}" \
                                --query 'ARN' --output text 2>/dev/null || echo "")
      [ "$EXTERNAL_ID_SECRET_ARN" = "None" ] && EXTERNAL_ID_SECRET_ARN=""
      # Recover the AxelSpire CI CMK ARN from the SSM parameter written by
      # phase5_apply, so 'outputs' / 'outputs-json' invocations in a fresh
      # shell (no --axelspire-artifact-kms-key-arn) can still report it.
      if [ -z "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" ]; then
        AXELSPIRE_ARTIFACT_KMS_KEY_ARN=$(aws ssm get-parameter \
                                          --name /3am/axelspire/artifact-kms-key-arn \
                                          --query 'Parameter.Value' --output text 2>/dev/null || echo "")
        [ "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" = "None" ] && AXELSPIRE_ARTIFACT_KMS_KEY_ARN=""
      fi
      STATE_BUCKET_NAME="3am-state-${ACCOUNT_ID}-${DEPLOYMENT_REGION}"
      aws s3api head-bucket --bucket "${STATE_BUCKET_NAME}" --region "${DEPLOYMENT_REGION}" 2>/dev/null || STATE_BUCKET_NAME=""
      restore_mgmt_creds
    fi
  fi
}

print_outputs_human () {
  cat <<EOF

================================================================
  3AM customer-org-setup — outputs
================================================================
  customer_name                       : ${CUSTOMER_NAME:-<unknown>}
  customer_id                         : ${CUSTOMER_ID:-<unknown>}
  mgmt_account_id                     : ${MGMT_ACCOUNT_ID:-<missing>}
  account_id                          : ${ACCOUNT_ID:-<missing>}
  account_name                        : ${ACCOUNT_NAME}
  ou_id                               : ${OU_ID:-<missing>}
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

  Phase 5 (bootstrap, in child account ${ACCOUNT_ID:-<missing>}):
  deployment_role_arn                 : ${DEPLOYMENT_ROLE_ARN:-<missing or skipped>}
  customer_cmk_arn                    : ${CUSTOMER_CMK_ARN:-<missing or skipped>}
  customer_cmk_alias                  : ${CUSTOMER_CMK_ALIAS}
  external_id_secret_arn              : ${EXTERNAL_ID_SECRET_ARN:-<missing or skipped>}
  state_bucket_name                   : ${STATE_BUCKET_NAME:-<missing or skipped>}
  state_lock_table_name               : ${STATE_LOCK_TABLE_NAME}
  axelspire_artifact_kms_key_arn      : ${AXELSPIRE_ARTIFACT_KMS_KEY_ARN:-<missing>}
  axelspire_artifact_s3_bucket_arn    : ${AXELSPIRE_ARTIFACT_S3_BUCKET_ARN:-<missing>}
================================================================

Hand off to AxelSpire:
  Send the file 3am-org-setup-outputs.json (in ${LOG_DIR})
  to AxelSpire. It contains every ARN/ID needed to onboard this account
  in the AxelSpire customer-onboard workflow.
EOF
}

print_outputs_json () {
  # Uses jq if available (CloudShell ships with jq); falls back to
  # a hand-built JSON string for portability.
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg customer_name              "${CUSTOMER_NAME}" \
      --arg customer_id                "${CUSTOMER_ID}" \
      --arg mgmt_account_id            "${MGMT_ACCOUNT_ID}" \
      --arg account_id                 "${ACCOUNT_ID}" \
      --arg account_name               "${ACCOUNT_NAME}" \
      --arg ou_id                      "${OU_ID}" \
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
        mgmt_account_id: $mgmt_account_id,
        account_id: $account_id,
        account_name: $account_name,
        ou_id: $ou_id,
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
    printf '  "mgmt_account_id": "%s",\n'                     "${MGMT_ACCOUNT_ID}"
    printf '  "account_id": "%s",\n'                          "${ACCOUNT_ID}"
    printf '  "account_name": "%s",\n'                        "${ACCOUNT_NAME}"
    printf '  "ou_id": "%s",\n'                               "${OU_ID}"
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
  # Quiet preflight: just need INSTANCE_ARN / IDSTORE_ID / ROOT_ID.
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
  if [[ $# -eq 0 ]]; then usage; exit 0; fi
  INVOCATION_ARGV=( "$@" )
  parse_args "$@"
  case "${COMMAND}" in
    help|--help|-h) usage; exit 0 ;;
  esac
  # outputs-json must emit clean JSON on stdout — initialise logging
  # only for commands that benefit from it.
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

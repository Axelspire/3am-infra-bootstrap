#!/usr/bin/env bash
# single-account-setup.sh — 3AM Identity Center / SCP setup inside an
# existing single AWS account.
#
# Use this when the 3AM workload runs in the same AWS account as the Org
# root (e.g. a freshly-signed-up AWS account that is its own Organization
# management account — typical for small customers and POCs). The caller's
# current account is used both as the SCP-owning Org-management context
# AND as the workload target for IAM Identity Center assignments. No new
# AWS account is created and no OU shuffle is performed.
#
# For the multi-account variant (creates a new child account in a 3AM OU),
# use customer-org-setup.sh instead.
#
# Idempotent: safe to re-run after a partial failure.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Defaults & globals
# ---------------------------------------------------------------------------
# SCP bodies are written to /tmp at runtime (see write_policy_files), so
# the script remains a single-file curl-and-run.
REGION_POLICY_FILE="/tmp/3am-region-deny.json"
ROOT_POLICY_FILE="/tmp/3am-root-user-deny.json"

ALLOWED_REGIONS_CSV="eu-west-1,us-east-1"
PLATFORM_ADMINS_GROUP="3AM-Platform-Admins"
BREAKGLASS_GROUP="3AM-BreakGlass"
EXTERNAL_IDP=false
SKIP_SCPS=false
AUTO_APPROVE=false
QUIET=false
LOG_DIR="${HOME}"
COMMAND="apply"

# Per-customer inputs (no defaults — must be supplied on first apply).
CUSTOMER_NAME=""
PLATFORM_ADMIN_USER=""
BREAKGLASS_USER=""

# Resolved at runtime.
INSTANCE_ARN=""
IDSTORE_ID=""
ROOT_ID=""
ACCOUNT_ID=""
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

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
init_logging () {
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/3am-single-account-setup-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  trap 'echo; echo "FAILED at line ${LINENO} (exit $?). Log: ${LOG_FILE}" >&2' ERR
  log "log file: ${LOG_FILE}"
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

Set up 3AM Identity Center (and optional SCPs) inside the AWS account
you are currently signed into. No new AWS account is created; the
current account is used as both the Org-management context AND the
workload target.

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
  --platform-admin-user EMAIL   First member of the platform-admin group
                                (UserName in Identity Center directory).
                                Default: Organization MasterAccountEmail.

Optional:
  --allowed-regions LIST        CSV, default: "eu-west-1,us-east-1".
                                Used to parameterise the region-deny SCP.
  --platform-admins-group NAME  Default: "3AM-Platform-Admins".
  --breakglass-group NAME       Default: "3AM-BreakGlass".
  --external-idp                Skip user/group creation; expect them to
                                come from an external IdP via SCIM.
  --skip-scps                   Do not create or attach the 3am-region-deny
                                / 3am-root-user-deny SCPs. SCPs are never
                                enforced against the management account
                                itself, so they are no-ops in a true
                                single-account topology, but they are
                                created and attached to root by default
                                so future child accounts inherit them.
  --auto-approve                Skip interactive confirmation.
  --log-dir PATH                Default: $HOME (CloudShell-persistent).
  --quiet                       Reduce console noise (file log is full).

Outputs commands take no per-customer flags; they re-resolve every value
from AWS using the group / permission-set names.

Examples:
  # Minimal: customer-name and platform-admin auto-derived from AWS
  ./single-account-setup.sh apply \
    --breakglass-user bob@acme.example.com

  # Explicit override of every input
  ./single-account-setup.sh apply \
    --customer-name "Acme Corp" \
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
      --customer-name)          CUSTOMER_NAME="$2"; shift 2 ;;
      --allowed-regions)        ALLOWED_REGIONS_CSV="$2"; shift 2 ;;
      --platform-admin-user)    PLATFORM_ADMIN_USER="$2"; shift 2 ;;
      --breakglass-user)        BREAKGLASS_USER="$2"; shift 2 ;;
      --platform-admins-group)  PLATFORM_ADMINS_GROUP="$2"; shift 2 ;;
      --breakglass-group)       BREAKGLASS_GROUP="$2"; shift 2 ;;
      --external-idp)           EXTERNAL_IDP=true; shift ;;
      --skip-scps)              SKIP_SCPS=true; shift ;;
      --auto-approve)           AUTO_APPROVE=true; shift ;;
      --log-dir)                LOG_DIR="$2"; shift 2 ;;
      --quiet)                  QUIET=true; shift ;;
      -h|--help)                usage; exit 0 ;;
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
  log "preflight: caller account = ${ACCOUNT_ID}"

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
    die "IAM Identity Center is not enabled in this region. Enable it in the console (one-time, Org-mgmt account) and re-run."
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
  id=$(aws organizations list-policies --filter SERVICE_CONTROL_POLICY \
        --query "Policies[?Name==\`${name}\`].Id | [0]" --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    [ -f "$file" ] || die "policy file not found: ${file}"
    log "creating SCP '${name}' from ${file}" >&2
    id=$(aws organizations create-policy \
          --name "${name}" --type SERVICE_CONTROL_POLICY \
          --description "managed by single-account-setup.sh" \
          --content "file://${file}" \
          --query 'Policy.PolicySummary.Id' --output text)
  else
    log "reusing SCP '${name}' = ${id}" >&2
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

# Fill in --customer-name and --platform-admin-user from AWS when the
# operator did not supply them. --breakglass-user is never auto-derived:
# the break-glass identity must be a deliberate choice, ideally distinct
# from the platform-admin identity. Called after preflight so
# ACCOUNT_ID is already resolved.
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

# ---------------------------------------------------------------------------
# apply — full setup, idempotent
# ---------------------------------------------------------------------------
do_apply () {
  if ! ${EXTERNAL_IDP}; then
    [ -n "$BREAKGLASS_USER" ] || die "--breakglass-user required (or pass --external-idp)"
  fi

  preflight
  resolve_apply_defaults

  say
  say "Customer:           ${CUSTOMER_NAME}"
  say "Target account:     ${ACCOUNT_ID} (current caller — used as workload account)"
  say "Allowed regions:    ${ALLOWED_REGIONS_CSV}"
  say "Identity Center:    ${INSTANCE_ARN}"
  say "Platform admin:     ${PLATFORM_ADMIN_USER:-<external IdP>}"
  say "Break-glass:        ${BREAKGLASS_USER:-<external IdP>}"
  say "External IdP:       ${EXTERNAL_IDP}"
  say "Skip SCPs:          ${SKIP_SCPS}"
  say
  if ! ${AUTO_APPROVE}; then
    read -r -p "Proceed? [y/N] " ans
    [ "${ans:-}" = "y" ] || die "aborted by operator"
  fi

  if ${SKIP_SCPS}; then
    log "== step 1/4: SCPs (skipped, --skip-scps) =="
  else
    log "== step 1/4: SCPs =="
    write_policy_files
    REGION_POLICY_ID=$(get_or_create_scp 3am-region-deny    "${REGION_POLICY_FILE}")
    ROOT_POLICY_ID=$(get_or_create_scp   3am-root-user-deny "${ROOT_POLICY_FILE}")
    # Attach to root: no-op for the management account itself (SCPs do
    # not apply there) but inherited by any future child accounts.
    attach_policy_if_missing "${REGION_POLICY_ID}" "${ROOT_ID}"
    attach_policy_if_missing "${ROOT_POLICY_ID}"   "${ROOT_ID}"
  fi

  log "== step 2/4: permission sets =="
  PS_PLATFORM_ARN=$(get_or_create_permission_set PlatformAdmin PT8H)
  PS_BREAKGLASS_ARN=$(get_or_create_permission_set BreakGlass  PT1H)
  attach_managed_policy_if_missing "${PS_PLATFORM_ARN}"   arn:aws:iam::aws:policy/AdministratorAccess
  attach_managed_policy_if_missing "${PS_BREAKGLASS_ARN}" arn:aws:iam::aws:policy/AdministratorAccess

  log "== step 3/4: groups / users =="
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

  log "== step 4/4: account assignments =="
  ensure_account_assignment "${ACCOUNT_ID}" "${PS_PLATFORM_ARN}"   GROUP "${PA_GROUP_ID}"
  ensure_account_assignment "${ACCOUNT_ID}" "${PS_BREAKGLASS_ARN}" GROUP "${BG_GROUP_ID}"

  log "== resolving AWSReservedSSO role ARNs (best-effort) =="
  PA_ROLE_ARN=$(resolve_reserved_sso_role_arn PlatformAdmin || true)
  BG_ROLE_ARN=$(resolve_reserved_sso_role_arn BreakGlass    || true)

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
}

print_outputs_human () {
  cat <<EOF

================================================================
  3AM single-account-setup — outputs
================================================================
  customer_name                     : ${CUSTOMER_NAME:-<unknown>}
  account_id                        : ${ACCOUNT_ID:-<missing>}
  identity_center_instance_arn      : ${INSTANCE_ARN:-<missing>}
  identity_store_id                 : ${IDSTORE_ID:-<missing>}
  region_deny_policy_id             : ${REGION_POLICY_ID:-<missing or skipped>}
  root_user_deny_policy_id          : ${ROOT_POLICY_ID:-<missing or skipped>}
  platform_admin_permission_set_arn : ${PS_PLATFORM_ARN:-<missing>}
  breakglass_permission_set_arn     : ${PS_BREAKGLASS_ARN:-<missing>}
  platform_admins_group_id          : ${PA_GROUP_ID:-<missing>}
  breakglass_group_id               : ${BG_GROUP_ID:-<missing>}
  platform_admin_role_arn           : ${PA_ROLE_ARN:-<pending — assignment not yet provisioned>}
  breakglass_role_arn               : ${BG_ROLE_ARN:-<pending — assignment not yet provisioned>}
================================================================

Feed into 3am-infra-bootstrap as:
  aws_account_id          = ${ACCOUNT_ID:-<missing>}
  customer_admin_role_arns = [
    "${PA_ROLE_ARN:-<missing>}",
    "${BG_ROLE_ARN:-<missing>}",
  ]
EOF
}

print_outputs_json () {
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg customer_name      "${CUSTOMER_NAME}" \
      --arg account_id         "${ACCOUNT_ID}" \
      --arg instance_arn       "${INSTANCE_ARN}" \
      --arg identity_store_id  "${IDSTORE_ID}" \
      --arg region_policy_id   "${REGION_POLICY_ID}" \
      --arg root_policy_id     "${ROOT_POLICY_ID}" \
      --arg ps_platform_arn    "${PS_PLATFORM_ARN}" \
      --arg ps_breakglass_arn  "${PS_BREAKGLASS_ARN}" \
      --arg pa_group_id        "${PA_GROUP_ID}" \
      --arg bg_group_id        "${BG_GROUP_ID}" \
      --arg pa_role_arn        "${PA_ROLE_ARN}" \
      --arg bg_role_arn        "${BG_ROLE_ARN}" \
      '{
        customer_name: $customer_name,
        account_id: $account_id,
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
      }'
  else
    printf '{\n'
    printf '  "customer_name": "%s",\n'                       "${CUSTOMER_NAME}"
    printf '  "account_id": "%s",\n'                          "${ACCOUNT_ID}"
    printf '  "identity_center_instance_arn": "%s",\n'        "${INSTANCE_ARN}"
    printf '  "identity_store_id": "%s",\n'                   "${IDSTORE_ID}"
    printf '  "region_deny_policy_id": "%s",\n'               "${REGION_POLICY_ID}"
    printf '  "root_user_deny_policy_id": "%s",\n'            "${ROOT_POLICY_ID}"
    printf '  "platform_admin_permission_set_arn": "%s",\n'   "${PS_PLATFORM_ARN}"
    printf '  "breakglass_permission_set_arn": "%s",\n'       "${PS_BREAKGLASS_ARN}"
    printf '  "platform_admins_group_id": "%s",\n'            "${PA_GROUP_ID}"
    printf '  "breakglass_group_id": "%s",\n'                 "${BG_GROUP_ID}"
    printf '  "platform_admin_role_arn": "%s",\n'             "${PA_ROLE_ARN}"
    printf '  "breakglass_role_arn": "%s"\n'                  "${BG_ROLE_ARN}"
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

main "$@"

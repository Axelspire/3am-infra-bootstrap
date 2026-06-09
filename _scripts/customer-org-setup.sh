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

# ---------------------------------------------------------------------------
# Defaults & globals
# ---------------------------------------------------------------------------
# SCP bodies are written to /tmp at runtime (see write_policy_files).
# This keeps the script fully self-contained: a single `curl` of this
# file is all the operator needs.
REGION_POLICY_FILE="/tmp/3am-region-deny.json"
ROOT_POLICY_FILE="/tmp/3am-root-user-deny.json"

ACCOUNT_NAME="3AM Production"
OU_NAME="3AM"
ALLOWED_REGIONS_CSV="eu-west-1,us-east-1"
PLATFORM_ADMINS_GROUP="3AM-Platform-Admins"
BREAKGLASS_GROUP="3AM-BreakGlass"
EXTERNAL_IDP=false
AUTO_APPROVE=false
QUIET=false
LOG_DIR="${HOME}"

# Per-customer inputs (no defaults — must be supplied on first apply).
CUSTOMER_NAME=""
ACCOUNT_EMAIL=""
PLATFORM_ADMIN_USER=""
BREAKGLASS_USER=""

# Resolved at runtime by preflight / apply.
INSTANCE_ARN=""
IDSTORE_ID=""
ROOT_ID=""
OU_ID=""
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
  LOG_FILE="${LOG_DIR}/3am-org-setup-$(date -u +%Y%m%dT%H%M%SZ).log"
  # Tee stdout/stderr to the log file. CloudShell $HOME persists across
  # sessions so the operator can download the file later.
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
Usage: customer-org-setup.sh [COMMAND] [OPTIONS]

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
  --account-name NAME           Default: "3AM Production".
  --ou-name NAME                Default: "3AM".
  --allowed-regions LIST        CSV, default: "eu-west-1,us-east-1".
  --platform-admins-group NAME  Default: "3AM-Platform-Admins".
  --breakglass-group NAME       Default: "3AM-BreakGlass".
  --external-idp                Skip user/group creation; expect them
                                to come from an external IdP via SCIM.
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
COMMAND="apply"
parse_args () {
  if [[ $# -gt 0 && "$1" != --* ]]; then COMMAND="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --customer-name)          CUSTOMER_NAME="$2"; shift 2 ;;
      --account-name)           ACCOUNT_NAME="$2"; shift 2 ;;
      --account-email)          ACCOUNT_EMAIL="$2"; shift 2 ;;
      --ou-name)                OU_NAME="$2"; shift 2 ;;
      --allowed-regions)        ALLOWED_REGIONS_CSV="$2"; shift 2 ;;
      --platform-admin-user)    PLATFORM_ADMIN_USER="$2"; shift 2 ;;
      --breakglass-user)        BREAKGLASS_USER="$2"; shift 2 ;;
      --platform-admins-group)  PLATFORM_ADMINS_GROUP="$2"; shift 2 ;;
      --breakglass-group)       BREAKGLASS_GROUP="$2"; shift 2 ;;
      --external-idp)           EXTERNAL_IDP=true; shift ;;
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

  EFFECTIVE_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
  [ -n "$EFFECTIVE_REGION" ] || EFFECTIVE_REGION="<unset>"
  log "preflight: effective region = ${EFFECTIVE_REGION} (regional APIs e.g. sso-admin target this region)"

  log "preflight: organization feature set"
  local fs
  fs=$(aws organizations describe-organization \
        --query 'Organization.FeatureSet' --output text 2>/dev/null) || \
    die "not logged into an Org-management account (or not part of an Organization)"
  [ "$fs" = "ALL" ] || die "Organization is in '${fs}' mode; ALL features required for SCPs"

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
# apply — full setup, idempotent
# ---------------------------------------------------------------------------
do_apply () {
  [ -n "$CUSTOMER_NAME" ]       || die "--customer-name required"
  [ -n "$ACCOUNT_EMAIL" ]       || die "--account-email required"
  if ! ${EXTERNAL_IDP}; then
    [ -n "$PLATFORM_ADMIN_USER" ] || die "--platform-admin-user required (or pass --external-idp)"
    [ -n "$BREAKGLASS_USER" ]     || die "--breakglass-user required (or pass --external-idp)"
  fi

  preflight

  say
  say "Customer:        ${CUSTOMER_NAME}"
  say "AWS account:     ${ACCOUNT_NAME} <${ACCOUNT_EMAIL}>"
  say "Parent OU:       ${OU_NAME}"
  say "Effective region: ${EFFECTIVE_REGION}"
  say "Allowed regions: ${ALLOWED_REGIONS_CSV}"
  say "Identity Center: ${INSTANCE_ARN}"
  say "External IdP:    ${EXTERNAL_IDP}"
  say
  if ! ${AUTO_APPROVE}; then
    read -r -p "Proceed? [y/N] " ans
    [ "${ans:-}" = "y" ] || die "aborted by operator"
  fi

  log "== step 1/6: OU =="
  OU_ID=$(get_or_create_ou "${OU_NAME}" "${ROOT_ID}")

  log "== step 2/6: AWS account =="
  ACCOUNT_ID=$(get_or_create_account "${ACCOUNT_NAME}" "${ACCOUNT_EMAIL}")
  move_account_if_needed "${ACCOUNT_ID}" "${OU_ID}"

  log "== step 3/6: SCPs =="
  write_policy_files
  REGION_POLICY_ID=$(get_or_create_scp 3am-region-deny    "${REGION_POLICY_FILE}")
  ROOT_POLICY_ID=$(get_or_create_scp   3am-root-user-deny "${ROOT_POLICY_FILE}")
  attach_policy_if_missing "${REGION_POLICY_ID}" "${OU_ID}"
  attach_policy_if_missing "${ROOT_POLICY_ID}"   "${OU_ID}"

  log "== step 4/6: permission sets =="
  PS_PLATFORM_ARN=$(get_or_create_permission_set PlatformAdmin PT8H)
  PS_BREAKGLASS_ARN=$(get_or_create_permission_set BreakGlass  PT1H)
  attach_managed_policy_if_missing "${PS_PLATFORM_ARN}"   arn:aws:iam::aws:policy/AdministratorAccess
  attach_managed_policy_if_missing "${PS_BREAKGLASS_ARN}" arn:aws:iam::aws:policy/AdministratorAccess

  log "== step 5/6: groups / users =="
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

  log "== step 6/6: account assignments =="
  ensure_account_assignment "${ACCOUNT_ID}" "${PS_PLATFORM_ARN}"   GROUP "${PA_GROUP_ID}"
  ensure_account_assignment "${ACCOUNT_ID}" "${PS_BREAKGLASS_ARN}" GROUP "${BG_GROUP_ID}"

  log "== resolving AWSReservedSSO role ARNs (best-effort) =="
  PA_ROLE_ARN=$(resolve_reserved_sso_role_arn "${ACCOUNT_ID}" PlatformAdmin || true)
  BG_ROLE_ARN=$(resolve_reserved_sso_role_arn "${ACCOUNT_ID}" BreakGlass    || true)

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
}

print_outputs_human () {
  cat <<EOF

================================================================
  3AM customer-org-setup — outputs
================================================================
  customer_name                     : ${CUSTOMER_NAME:-<unknown>}
  account_id                        : ${ACCOUNT_ID:-<missing>}
  account_name                      : ${ACCOUNT_NAME}
  ou_id                             : ${OU_ID:-<missing>}
  identity_center_instance_arn      : ${INSTANCE_ARN:-<missing>}
  identity_store_id                 : ${IDSTORE_ID:-<missing>}
  region_deny_policy_id             : ${REGION_POLICY_ID:-<missing>}
  root_user_deny_policy_id          : ${ROOT_POLICY_ID:-<missing>}
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
  # Uses jq if available (CloudShell ships with jq); falls back to
  # a hand-built JSON string for portability.
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg customer_name      "${CUSTOMER_NAME}" \
      --arg account_id         "${ACCOUNT_ID}" \
      --arg account_name       "${ACCOUNT_NAME}" \
      --arg ou_id              "${OU_ID}" \
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
        account_name: $account_name,
        ou_id: $ou_id,
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
    printf '  "account_name": "%s",\n'                        "${ACCOUNT_NAME}"
    printf '  "ou_id": "%s",\n'                               "${OU_ID}"
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

main "$@"

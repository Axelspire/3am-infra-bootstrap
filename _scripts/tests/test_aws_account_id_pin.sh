#!/usr/bin/env bash
# DEPLOY-32: never reuse Org accounts by Name alone; pin via describe-account.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/_scripts/customer-org-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

die () { echo "FAIL: $*" >&2; exit 1; }
pass () { echo "OK: $*"; }

cat > "${TMP}/harness.sh" <<'EOS'
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "LOG: $*" >&2; }
AUTO_APPROVE=true
ACCOUNT_NAME=""
AWS_ACCOUNT_ID=""
aws() {
  local args="$*"
  case "${args}" in
    *"get-caller-identity"*) echo "436667402144"; return 0 ;;
    *"describe-organization"*) echo "436667402144"; return 0 ;;
    *"describe-account"*"415571557053"*)
      printf '415571557053\t3AM Eyes Workload\tACTIVE\n'; return 0 ;;
    *"describe-account"*"085068687349"*)
      printf '085068687349\t3AM Production\tACTIVE\n'; return 0 ;;
    *"describe-account"*)
      return 1 ;;
    *"list-accounts"*"--output json"*)
      cat <<'JSON'
{"Accounts":[
  {"Id":"085068687349","Name":"3AM Production","Status":"ACTIVE"},
  {"Id":"415571557053","Name":"3AM Eyes Workload","Status":"ACTIVE"},
  {"Id":"436667402144","Name":"Org Management","Status":"ACTIVE"}
]}
JSON
      return 0 ;;
  esac
  echo "unexpected aws mock: ${args}" >&2
  return 1
}
EOS

awk '
  /^_validate_aws_account_id_format \(\)/ {on=1}
  /^org_describe_account \(\)/ {on=1}
  /^org_account_id_by_name \(\)/ {on=1}
  /^org_account_status_by_name \(\)/ {on=1}
  /^_die_account_not_in_org \(\)/ {on=1}
  /^get_or_create_account \(\)/ {on=1; want_close=1}
  on {print}
  want_close && /^}/ {exit}
' "${SCRIPT}" >> "${TMP}/harness.sh"

set +e
out="$(bash -c 'source "'"${TMP}"'/harness.sh"; AWS_ACCOUNT_ID=""; get_or_create_account "3AM Production" "dan@example.com"' 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected name-collision failure without pin"
echo "$out" | grep -q "already exists as 085068687349" || die "missing collision message: $out"
pass "refuses name-only reuse of 3AM Production"

set +e
out="$(bash -c 'source "'"${TMP}"'/harness.sh"; AWS_ACCOUNT_ID="415571557053"; get_or_create_account "3AM Production" "dan@example.com"' 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected name/id mismatch failure"
echo "$out" | grep -q "resolves to 085068687349" || die "missing mismatch message: $out"
pass "refuses account-name/id mismatch"

out="$(bash -c 'source "'"${TMP}"'/harness.sh"; AWS_ACCOUNT_ID="415571557053"; get_or_create_account "3AM Eyes" "dan@example.com"' 2>/dev/null)"
[[ "${out}" == "415571557053" ]] || die "expected pinned id, got: ${out}"
pass "reuses pinned workload account id via describe-account"

set +e
out="$(bash -c 'source "'"${TMP}"'/harness.sh"; AWS_ACCOUNT_ID="999999999999"; get_or_create_account "Nope" "dan@example.com"' 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected missing-account failure"
echo "$out" | grep -q "not found in this Organization" || die "missing not-found message: $out"
echo "$out" | grep -q "describe-account" || die "missing diagnostic hint: $out"
pass "missing pin fails with describe-account diagnostics"

grep -q 'BOOTSTRAP_VERSION="0.2.34"' "${SCRIPT}" \
  || die "customer-org-setup.sh not bumped to 0.2.34"
grep -q 'BOOTSTRAP_VERSION="0.2.34"' "${ROOT}/_scripts/single-account-setup.sh" \
  || die "single-account-setup.sh not bumped to 0.2.34"
grep -q 'org_describe_account' "${SCRIPT}" || die "missing org_describe_account helper"
pass "BOOTSTRAP_VERSION 0.2.34 + describe-account pin"

echo "ALL PASS"

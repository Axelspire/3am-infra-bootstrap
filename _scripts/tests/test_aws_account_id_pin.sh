#!/usr/bin/env bash
# DEPLOY-32: never reuse Org accounts by Name alone; require id pin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/_scripts/customer-org-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

die () { echo "FAIL: $*" >&2; exit 1; }
pass () { echo "OK: $*"; }

# Source only the pin helpers into a harness with a stubbed aws.
cat > "${TMP}/harness.sh" <<'EOS'
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "LOG: $*" >&2; }
AUTO_APPROVE=true
ACCOUNT_NAME=""
AWS_ACCOUNT_ID=""
aws() {
  local args="$*"
  case "${args}" in
    *"Name==\`3AM Production\`"*".Id |"*) echo "085068687349"; return 0 ;;
    *"Name==\`3AM Production\`"*".Status |"*) echo "ACTIVE"; return 0 ;;
    *"Id==\`085068687349\`"*".Name |"*) echo "3AM Production"; return 0 ;;
    *"Id==\`085068687349\`"*".Id |"*) echo "085068687349"; return 0 ;;
    *"Id==\`415571557053\`"*".Name |"*) echo "3AM Eyes Workload"; return 0 ;;
    *"Id==\`415571557053\`"*".Id |"*) echo "415571557053"; return 0 ;;
    *"Name==\`3AM Eyes\`"*) echo "None"; return 0 ;;
  esac
  echo "unexpected aws mock: ${args}" >&2
  return 1
}
EOS

awk '
  /^_validate_aws_account_id_format \(\)/ {on=1}
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
pass "reuses pinned workload account id"

grep -q 'BOOTSTRAP_VERSION="0.2.33"' "${SCRIPT}" \
  || die "customer-org-setup.sh not bumped to 0.2.33"
grep -q 'BOOTSTRAP_VERSION="0.2.33"' "${ROOT}/_scripts/single-account-setup.sh" \
  || die "single-account-setup.sh not bumped to 0.2.33"
grep -q -- '--aws-account-id' "${SCRIPT}" || die "missing --aws-account-id flag docs/parse"
grep -q 'prompt_workload_account_id' "${SCRIPT}" || die "missing interactive prompt helper"
pass "BOOTSTRAP_VERSION 0.2.33 + flag/prompt present"

echo "ALL PASS"

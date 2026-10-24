#!/usr/bin/env bash
# Copyright (c) 2026 Axelspire Inc. All rights reserved.
# Proprietary. Unauthorized use prohibited. support3am@axelspire.com
#
# DAT.03.L2.b — residency contract check (no AWS credentials).
# Proves Pass B handoff fixtures require non-empty allowed_regions and that
# load_pass_b_handoff rejects blank/missing values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/_scripts/single-account-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

die () { echo "FAIL: $*" >&2; exit 1; }
pass () { echo "OK: $*"; }

# Extract handoff helpers through the end of load_pass_b_handoff (column-0 }).
LOADER="$(awk '
  /^DEFAULT_HANDOFF_PATH=/ {on=1}
  on {print}
  /^load_pass_b_handoff \(\)/ {want_close=1}
  want_close && /^}/ {exit}
' "${SCRIPT}")"

make_handoff () {
  local path="$1"
  local allowed="${2}"
  cat > "${path}" <<EOF
{
  "schema_version": 1,
  "purpose": "pass-b-handoff",
  "expires_at": "2099-01-01T00:00:00Z",
  "customer_id": "acme-corp",
  "customer_name": "Acme Corp",
  "account_id": "123456789012",
  "region": "eu-west-1",
  "deployment_region": "eu-west-1",
  "allowed_regions": ${allowed},
  "bootstrap_variant": "single-account",
  "bootstrap_script": "single-account-setup.sh",
  "platform_admin_user": "alice@acme.example.com",
  "breakglass_user": "bob@acme.example.com",
  "account_email": "",
  "axelspire_ci_account_id": "033113129683",
  "axelspire_artifact_kms_key_arn": "arn:aws:kms:eu-west-1:033113129683:key/mrk-abc",
  "axelspire_artifact_s3_bucket_arn": "arn:aws:s3:::3am-ci-artifacts-033113129683",
  "skip_org": true
}
EOF
}

# --- Fixture contract: checked-in handoff examples must declare regions ---
FIXTURE_COUNT=0
while IFS= read -r -d '' f; do
  FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
  regions="$(jq -r '.allowed_regions // empty' "${f}")"
  [[ -n "${regions}" ]] || die "fixture ${f}: allowed_regions missing or blank"
  pass "fixture $(basename "${f}"): allowed_regions=${regions}"
done < <(find "${ROOT}/_scripts/tests" -type f \( -name '*handoff*.json' -o -name '*pass-b*.json' \) -print0 2>/dev/null || true)

# Inline happy-path fixture (also serves when no checked-in JSON fixtures exist).
GOOD="${TMP}/good-handoff.json"
make_handoff "${GOOD}" '"eu-west-1"'
regions="$(jq -r '.allowed_regions // empty' "${GOOD}")"
[[ -n "${regions}" ]] || die "good fixture blank"
pass "inline fixture has non-empty allowed_regions"

# Loader accepts non-empty allowed_regions
eval "$(bash -c '
  die(){ echo "ERROR: $*" >&2; exit 1; }
  log(){ :; }
  '"${LOADER}"'
  FROM_HANDOFF_PATH="'"${GOOD}"'"
  load_pass_b_handoff
  printf "ALLOWED_REGIONS_CSV=%q\n" "$ALLOWED_REGIONS_CSV"
')"
[[ "${ALLOWED_REGIONS_CSV}" == "eu-west-1" ]] || die "loader did not keep allowed_regions"
pass "loader keeps non-empty allowed_regions"

# Blank string → reject
BLANK="${TMP}/blank-handoff.json"
make_handoff "${BLANK}" '""'
set +e
out="$(bash -c '
  die(){ echo "ERROR: $*" >&2; exit 1; }
  log(){ :; }
  '"${LOADER}"'
  FROM_HANDOFF_PATH="'"${BLANK}"'"
  load_pass_b_handoff
' 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected blank allowed_regions failure"
echo "$out" | grep -qi 'allowed_regions' || die "missing allowed_regions message: $out"
pass "rejects blank allowed_regions"

# Missing key → reject
MISSING="${TMP}/missing-handoff.json"
jq 'del(.allowed_regions)' "${GOOD}" > "${MISSING}"
set +e
out="$(bash -c '
  die(){ echo "ERROR: $*" >&2; exit 1; }
  log(){ :; }
  '"${LOADER}"'
  FROM_HANDOFF_PATH="'"${MISSING}"'"
  load_pass_b_handoff
' 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected missing allowed_regions failure"
echo "$out" | grep -qi 'allowed_regions' || die "missing allowed_regions message: $out"
pass "rejects missing allowed_regions"

# Whitespace-only → reject (loader trims before the non-empty check)
WS="${TMP}/ws-handoff.json"
make_handoff "${WS}" '"   "'
set +e
out="$(bash -c '
  die(){ echo "ERROR: $*" >&2; exit 1; }
  log(){ :; }
  '"${LOADER}"'
  FROM_HANDOFF_PATH="'"${WS}"'"
  load_pass_b_handoff
' 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected whitespace allowed_regions failure"
echo "$out" | grep -qi 'allowed_regions' || die "missing allowed_regions message: $out"
pass "rejects whitespace-only allowed_regions"

echo "ALL PASS (fixtures_checked=${FIXTURE_COUNT})"

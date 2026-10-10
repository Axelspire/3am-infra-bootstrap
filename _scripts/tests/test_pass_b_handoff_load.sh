#!/usr/bin/env bash
# DEPLOY-33: --from-handoff locks identity and rejects CLI overrides.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/_scripts/single-account-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

die () { echo "FAIL: $*" >&2; exit 1; }
pass () { echo "OK: $*"; }

HANDOFF="${TMP}/3am-pass-b-handoff.json"
cat > "${HANDOFF}" <<EOF
{
  "schema_version": 1,
  "purpose": "pass-b-handoff",
  "expires_at": "2099-01-01T00:00:00Z",
  "customer_id": "acme-corp",
  "customer_name": "Acme Corp",
  "account_id": "123456789012",
  "region": "eu-west-1",
  "deployment_region": "eu-west-1",
  "allowed_regions": "eu-west-1",
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

# Source only the loader by extracting it — exercise via bash -c with stubs.
export HOME="${TMP}"
# HANDOFF already lives at $HOME/3am-pass-b-handoff.json

# Reject conflicting CLI
set +e
out="$(bash -c '
  source /dev/null
  die(){ echo "ERROR: $*" >&2; exit 1; }
  log(){ :; }
  '"$(sed -n "/^DEFAULT_HANDOFF_PATH=/,/^}/p" "${SCRIPT}")"'
  CLI_SET_CUSTOMER_ID=true
  FROM_HANDOFF_PATH="'"${HANDOFF}"'"
  load_pass_b_handoff
' 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected conflict failure"
echo "$out" | grep -q "do not pass locked flags" || die "missing conflict message: $out"
pass "rejects locked CLI flags"

# Happy path loads values
eval "$(bash -c '
  die(){ echo "ERROR: $*" >&2; exit 1; }
  log(){ :; }
  '"$(sed -n "/^DEFAULT_HANDOFF_PATH=/,/^}/p" "${SCRIPT}")"'
  FROM_HANDOFF_PATH="'"${HANDOFF}"'"
  load_pass_b_handoff
  printf "CUSTOMER_ID=%q\n" "$CUSTOMER_ID"
  printf "SKIP_ORG=%q\n" "$SKIP_ORG"
  printf "AXELSPIRE_ARTIFACT_KMS_KEY_ARN=%q\n" "$AXELSPIRE_ARTIFACT_KMS_KEY_ARN"
')"
[[ "${CUSTOMER_ID}" == "acme-corp" ]] || die "customer_id not loaded"
[[ "${SKIP_ORG}" == "true" ]] || die "SKIP_ORG not set"
[[ "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" == arn:aws:kms:* ]] || die "kms not loaded"
pass "loads locked fields and sets SKIP_ORG"

# Expired handoff
jq '.expires_at="2000-01-01T00:00:00Z"' "${HANDOFF}" > "${HANDOFF}.exp"
set +e
out="$(bash -c '
  die(){ echo "ERROR: $*" >&2; exit 1; }
  log(){ :; }
  '"$(sed -n "/^DEFAULT_HANDOFF_PATH=/,/^}/p" "${SCRIPT}")"'
  FROM_HANDOFF_PATH="'"${HANDOFF}.exp"'"
  load_pass_b_handoff
' 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected expiry failure"
echo "$out" | grep -qi expired || die "missing expiry message: $out"
pass "rejects expired handoff"

echo "ALL PASS"

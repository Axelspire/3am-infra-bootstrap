#!/usr/bin/env bash
# Unit tests for phase5_validate_axelspire_kms_arn in customer-org-setup.sh.
#
# The validation gates --axelspire-artifact-kms-key-arn on `apply`: the
# value must be a key-ID ARN (not an alias ARN), and its region must
# equal DEPLOYMENT_REGION (DynamoDB SSE-KMS requires a same-region key).
#
# Sources the script under a BASH_SOURCE guard so main() is not invoked,
# then exercises the function in subshells with curated globals. The
# real `die` is shadowed by a test stub that writes the message to
# stderr and exits non-zero, so a failed validation cleanly returns 1.
#
# Usage: bash _scripts/tests/test_phase5_validate_axelspire_kms_arn.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/_scripts/customer-org-setup.sh"

# shellcheck disable=SC1090
source "${SCRIPT}"

# Override die — the real one logs to a file that isn't initialised
# without init_logging, and we want a clean exit code only.
die () { printf 'die: %s\n' "$*" >&2; exit 1; }
log () { :; }

PASS=0
FAIL=0
ok  () { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad () { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

# Run the validator in a subshell with the named globals set.
# Args: <command> <region> <arn> -> 0 on accept, non-zero on reject.
run_validate () {
  local cmd="$1" region="$2" arn="$3"
  (
    set +e
    COMMAND="${cmd}"
    DEPLOYMENT_REGION="${region}"
    AXELSPIRE_ARTIFACT_KMS_KEY_ARN="${arn}"
    phase5_validate_axelspire_kms_arn 2>/dev/null
  )
}

expect_accept () {
  local label="$1"; shift
  if run_validate "$@"; then ok "${label}"; else bad "${label} (expected accept)"; fi
}
expect_reject () {
  local label="$1"; shift
  if ! run_validate "$@"; then ok "${label}"; else bad "${label} (expected reject)"; fi
}

echo "== Validation skipped on non-apply commands =="
expect_accept "preflight skips validation (empty ARN)"      preflight    eu-west-1 ""
expect_accept "outputs-json skips validation (alias ARN)"   outputs-json eu-west-1 "arn:aws:kms:eu-west-1:033113129683:alias/3am-ci/acme"
expect_accept "outputs skips validation (wrong region)"     outputs      eu-west-1 "arn:aws:kms:us-east-1:033113129683:key/00000000-0000-0000-0000-000000000000"

echo "== Apply: missing ARN =="
expect_reject "apply rejects empty ARN" apply eu-west-1 ""

echo "== Apply: ARN shape =="
expect_reject "apply rejects alias ARN" \
  apply us-east-1 "arn:aws:kms:us-east-1:033113129683:alias/3am-ci/acme"
expect_reject "apply rejects bare key id (no arn: prefix)" \
  apply us-east-1 "mrk-7b53fb1ed2ce4389b989b29d2ed2ec4b"
expect_reject "apply rejects bare UUID (no arn: prefix)" \
  apply us-east-1 "00000000-0000-0000-0000-000000000000"
expect_reject "apply rejects key/<id> with extra path segment" \
  apply us-east-1 "arn:aws:kms:us-east-1:033113129683:key/abc/extra"
expect_reject "apply rejects non-kms ARN" \
  apply us-east-1 "arn:aws:s3:::3am-ci-artifacts-033113129683"
expect_reject "apply rejects malformed ARN (missing partition)" \
  apply us-east-1 "arn::kms:us-east-1:033113129683:key/00000000-0000-0000-0000-000000000000"
expect_accept "apply accepts well-formed key-ID ARN (aws partition, UUID)" \
  apply us-east-1 "arn:aws:kms:us-east-1:033113129683:key/00000000-0000-0000-0000-000000000000"
expect_accept "apply accepts well-formed key-ID ARN (aws-cn partition, UUID)" \
  apply cn-north-1 "arn:aws-cn:kms:cn-north-1:033113129683:key/abcdef12-3456-7890-abcd-ef1234567890"
expect_accept "apply accepts well-formed MRK key-ID ARN" \
  apply eu-west-1 "arn:aws:kms:eu-west-1:033113129683:key/mrk-7b53fb1ed2ce4389b989b29d2ed2ec4b"

echo "== Apply: region must match DEPLOYMENT_REGION =="
expect_reject "apply rejects mismatched region (primary vs deployment)" \
  apply us-east-1 "arn:aws:kms:eu-west-1:033113129683:key/00000000-0000-0000-0000-000000000000"
expect_reject "apply rejects mismatched region (different replica)" \
  apply us-east-1 "arn:aws:kms:eu-central-1:033113129683:key/00000000-0000-0000-0000-000000000000"
expect_accept "apply accepts matching region (eu-west-1)" \
  apply eu-west-1 "arn:aws:kms:eu-west-1:033113129683:key/11111111-2222-3333-4444-555555555555"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]

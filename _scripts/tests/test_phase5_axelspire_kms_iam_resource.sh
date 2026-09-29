#!/usr/bin/env bash
# Copyright (c) 2026 Axelspire Inc. All rights reserved.
# Proprietary. Unauthorized use prohibited. support3am@axelspire.com

# Unit tests for phase5_axelspire_kms_iam_resource_arn (BOOTSTRAP-1).
#
# MRK keys must use region=* in IAM Resource so add-region Phase 5 re-runs
# do not drop the primary-region ARN. Non-MRK keys stay exact.
#
# Usage: bash _scripts/tests/test_phase5_axelspire_kms_iam_resource.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/_scripts/customer-org-setup.sh"

# shellcheck disable=SC1090
source "${SCRIPT}"

die () { printf 'die: %s\n' "$*" >&2; exit 1; }
log () { :; }

PASS=0
FAIL=0
ok  () { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad () { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

expect_eq () {
  local label="$1" want="$2" got="$3"
  if [ "${want}" = "${got}" ]; then ok "${label}"; else
    bad "${label} (want=${want} got=${got})"
  fi
}

PARTITION=aws

echo "== MRK: region wildcard =="
AXELSPIRE_ARTIFACT_KMS_KEY_ARN="arn:aws:kms:eu-central-1:033113129683:key/mrk-a651cdd4f2084e62a3e4310a16298a54"
got="$(phase5_axelspire_kms_iam_resource_arn)"
expect_eq "MRK Frankfurt → kms:* same key id" \
  "arn:aws:kms:*:033113129683:key/mrk-a651cdd4f2084e62a3e4310a16298a54" \
  "${got}"

AXELSPIRE_ARTIFACT_KMS_KEY_ARN="arn:aws:kms:eu-west-1:033113129683:key/mrk-a651cdd4f2084e62a3e4310a16298a54"
got="$(phase5_axelspire_kms_iam_resource_arn)"
expect_eq "MRK Ireland → same wildcard ARN" \
  "arn:aws:kms:*:033113129683:key/mrk-a651cdd4f2084e62a3e4310a16298a54" \
  "${got}"

echo "== Non-MRK: exact ARN =="
AXELSPIRE_ARTIFACT_KMS_KEY_ARN="arn:aws:kms:eu-west-1:033113129683:key/00000000-0000-0000-0000-000000000000"
got="$(phase5_axelspire_kms_iam_resource_arn)"
expect_eq "UUID key keeps exact regional ARN" \
  "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}" \
  "${got}"

echo "== compute sets IAM var =="
COMMAND=apply
DEPLOYMENT_REGION=eu-central-1
AXELSPIRE_ARTIFACT_KMS_KEY_ARN="arn:aws:kms:eu-central-1:033113129683:key/mrk-deadbeefcafebabe0123456789abcdef"
AXELSPIRE_ARTIFACT_S3_BUCKET_ARN=""
AXELSPIRE_CI_ACCOUNT_ID=033113129683
phase5_compute_axelspire_arns
expect_eq "compute fills AXELSPIRE_ARTIFACT_KMS_IAM_RESOURCE_ARN" \
  "arn:aws:kms:*:033113129683:key/mrk-deadbeefcafebabe0123456789abcdef" \
  "${AXELSPIRE_ARTIFACT_KMS_IAM_RESOURCE_ARN}"
expect_eq "compute keeps exact ARN for SSE/SSM" \
  "arn:aws:kms:eu-central-1:033113129683:key/mrk-deadbeefcafebabe0123456789abcdef" \
  "${AXELSPIRE_ARTIFACT_KMS_KEY_ARN}"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]

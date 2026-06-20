#!/usr/bin/env bash
# Fail when Phase 5 bootstrap helpers drift between single-account-setup.sh
# and customer-org-setup.sh. IAM policy JSON heredocs and shared helpers
# must stay in sync (ManagedBy script names are normalized).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SINGLE="${REPO_ROOT}/_scripts/single-account-setup.sh"
ORG="${REPO_ROOT}/_scripts/customer-org-setup.sh"

python3 - "${SINGLE}" "${ORG}" <<'PY'
import re, sys
from pathlib import Path

single = Path(sys.argv[1]).read_text()
org = Path(sys.argv[2]).read_text()

def norm(text: str) -> str:
    return (
        text.replace("single-account-setup.sh", "BOOTSTRAP_SCRIPT")
        .replace("customer-org-setup.sh", "BOOTSTRAP_SCRIPT")
    )

def extract_heredocs(text: str) -> dict[str, str]:
    out = {}
    for m in re.finditer(
        r'cat > "\$\{([A-Z_]+)\}" <<EOF\n(.*?)\nEOF',
        text,
        re.S,
    ):
        out[m.group(1)] = m.group(1)
    return out

policy_vars = [
    "PERMS_POLICY_FILE",
    "PERMS_EC2_FILE",
    "PERMS_EXTRA_FILE",
  "PERMS_ONBOARDING_FILE",
  "PERMS_INFRA_FILE",
  "CMK_POLICY_FILE",
    "STATE_BUCKET_POLICY_FILE",
    "DRIFT_STATE_POLICY_FILE",
]

errors = []
for var in policy_vars:
    pat = rf'cat > "\$\{{{var}\}}" <<EOF\n(.*?)\nEOF'
    sm = re.search(pat, single, re.S)
    om = re.search(pat, org, re.S)
    if not sm or not om:
        errors.append(f"missing heredoc {var} in one script")
        continue
    if sm.group(1) != om.group(1):
        errors.append(f"policy heredoc drift: {var}")

funcs = [
    "phase5_validate_axelspire_kms_arn",
    "phase5_compute_axelspire_arns",
    "phase5_write_policy_files",
    "phase5_get_or_create_deployment_role",
    "phase5_put_role_inline_policies",
    "phase5_write_drift_reader_policy_files",
    "phase5_get_or_create_drift_reader_role",
    "phase5_put_drift_reader_policies",
    "phase5_put_cmk_policy",
    "phase5_get_or_create_external_id_secret",
    "phase5_read_external_id_value",
    "phase5_get_or_create_state_bucket",
    "phase5_get_or_create_lock_table",
    "phase5_put_ssm_params",
]

def extract_fn(text: str, name: str) -> str | None:
    m = re.search(rf"^{name} \(\) \{{\n", text, re.M)
    if not m:
        return None
    start = m.start()
    depth = 0
    i = m.end() - 1
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
        i += 1
    return None

for fn in funcs:
    sf = extract_fn(single, fn)
    of = extract_fn(org, fn)
    if sf is None or of is None:
        errors.append(f"missing function {fn}")
        continue
    if norm(sf) != norm(of):
        errors.append(f"function drift: {fn}")

if errors:
    print("Phase 5 bootstrap parity check FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print("Phase 5 bootstrap parity check OK")
PY

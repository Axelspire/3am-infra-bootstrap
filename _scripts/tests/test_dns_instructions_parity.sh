#!/usr/bin/env bash
# Fail when the shared DNS instruction helper drifts, or when one bootstrap
# script wires it in but the other does not. The DNS logic MUST live only in
# bootstrap-dns-instructions.inc.sh (sourced by both), never copy-pasted.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INC="${REPO_ROOT}/_scripts/bootstrap-dns-instructions.inc.sh"
SINGLE="${REPO_ROOT}/_scripts/single-account-setup.sh"
ORG="${REPO_ROOT}/_scripts/customer-org-setup.sh"

errors=()

[[ -f "${INC}" ]] || errors+=("missing shared include bootstrap-dns-instructions.inc.sh")

# The include must define the documented helper surface.
for fn in \
  dns_env \
  dns_public_axel_fqdn dns_public_ocsp_fqdn dns_public_comms_fqdn \
  dns_infra_api_fqdn dns_infra_ocsp_fqdn dns_infra_comms_fqdn \
  print_dns_instructions_human dns_instructions_json; do
  if ! grep -qE "^${fn} +\(\) +\{" "${INC}"; then
    errors+=("include missing helper: ${fn}")
  fi
done

# Both scripts must wire the include + outputs identically.
for f in "${SINGLE}" "${ORG}"; do
  name="$(basename "${f}")"
  grep -q "bootstrap-dns-instructions.inc.sh" "${f}" || errors+=("${name}: does not source the DNS include")
  grep -q "print_dns_instructions_human" "${f}"      || errors+=("${name}: does not call print_dns_instructions_human")
  grep -q -- "--argjson dns" "${f}"                  || errors+=("${name}: JSON output missing --argjson dns")
  grep -q "dns: \$dns" "${f}"                         || errors+=("${name}: JSON object missing dns key")
  grep -q '"dns_infra_api_fqdn"' "${f}"              || errors+=("${name}: jq-less fallback missing dns_infra_api_fqdn")
done

if ((${#errors[@]})); then
  echo "DNS instructions parity check FAILED:" >&2
  for e in "${errors[@]}"; do echo "  - ${e}" >&2; done
  exit 1
fi

echo "DNS instructions parity check OK"

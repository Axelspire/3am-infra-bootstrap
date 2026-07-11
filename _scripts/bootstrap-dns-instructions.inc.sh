# bootstrap-dns-instructions.inc.sh — shared DNS instruction/formula helpers.
# Sourced by customer-org-setup.sh and single-account-setup.sh so the
# customer-facing DNS hand-off is emitted identically from both variants.
#
# These helpers only compute deterministic NAMES/FORMULAS from customer_id +
# region + env. They NEVER create DNS records: the platform 3am.global names,
# the customer BYO CNAMEs, and any WAF records are all created OUTSIDE these
# scripts (see 3AM_ARCHITECTURE.md). ACM validation CNAMEs for BYO do not exist
# yet at bootstrap time (they appear only after a certificate is requested).
#
# Expects the caller to define (both scripts already do):
#   CUSTOMER_ID          customer slug
#   DEPLOYMENT_REGION    primary/deployment region for this run
# Optional:
#   DNS_ENV              env label for the 3amops infra zone (default: prod)
#   BYO_PRIMARY_FQDN     customer primary (axel) FQDN, to personalize BYO lines
#   BYO_OCSP_FQDN        customer ocsp FQDN, to personalize BYO lines

dns_env () { echo "${DNS_ENV:-prod}"; }

# --- platform zero-touch public names (in AxelSpire's 3am.global zone) ---
dns_public_axel_fqdn  () { echo "axel.${1:-${CUSTOMER_ID}}.3am.global"; }
dns_public_ocsp_fqdn  () { echo "ocsp.${1:-${CUSTOMER_ID}}.3am.global"; }
dns_public_comms_fqdn () { echo "comms.${1:-${CUSTOMER_ID}}.3am.global"; }

# --- region-qualified infra targets (in the customer's 3amops zone) ---
# Always created per region by the in-account TF (3am-infra/ocsp/core).
#   <label>.<region>.<customer_id>.<env>.3amops.com
_dns_infra_fqdn () {
  local label="$1" region="${2:-${DEPLOYMENT_REGION}}" cid="${3:-${CUSTOMER_ID}}" env="${4:-$(dns_env)}"
  echo "${label}.${region}.${cid}.${env}.3amops.com"
}
dns_infra_api_fqdn   () { _dns_infra_fqdn api  "$@"; }
dns_infra_ocsp_fqdn  () { _dns_infra_fqdn ocsp "$@"; }
dns_infra_comms_fqdn () { _dns_infra_fqdn comms "$@"; }

# --- customer-facing human block ---
print_dns_instructions_human () {
  local env; env="$(dns_env)"
  local axel ocsp comms api_t ocsp_t comms_t
  axel="$(dns_public_axel_fqdn)"
  ocsp="$(dns_public_ocsp_fqdn)"
  comms="$(dns_public_comms_fqdn)"
  api_t="$(dns_infra_api_fqdn)"
  ocsp_t="$(dns_infra_ocsp_fqdn)"
  comms_t="$(dns_infra_comms_fqdn)"

  cat <<EOF

  DNS (platform — no customer action required):
    primary : ${axel}
    ocsp    : ${ocsp}
    comms   : ${comms} -> ${comms_t}

  DNS (optional BYO — customer creates CNAMEs once, then we renew forever):
    ${BYO_PRIMARY_FQDN:-<your-primary-fqdn>}  CNAME  ${axel}.
    ${BYO_OCSP_FQDN:-<your-ocsp-fqdn>}     CNAME  ${ocsp}.
    # ACM validation CNAMEs: provided after cert request (onboard / dns-activate)

  Region-qualified infra targets (created in your 3amops zone by deploy):
    api   : ${api_t}
    ocsp  : ${ocsp_t}
    comms : ${comms_t}
EOF
}

# --- machine-readable block for the outputs JSON (jq object) ---
# Emits the "dns" object; callers merge it into their outputs JSON.
dns_instructions_json () {
  local env; env="$(dns_env)"
  jq -n \
    --arg env         "${env}" \
    --arg axel        "$(dns_public_axel_fqdn)" \
    --arg ocsp        "$(dns_public_ocsp_fqdn)" \
    --arg comms       "$(dns_public_comms_fqdn)" \
    --arg api_infra   "$(dns_infra_api_fqdn)" \
    --arg ocsp_infra  "$(dns_infra_ocsp_fqdn)" \
    --arg comms_infra "$(dns_infra_comms_fqdn)" \
    '{
      env: $env,
      platform: {
        primary_fqdn: $axel,
        ocsp_fqdn:    $ocsp,
        comms_fqdn:   $comms
      },
      infra: {
        api_fqdn:   $api_infra,
        ocsp_fqdn:  $ocsp_infra,
        comms_fqdn: $comms_infra
      },
      byo_traffic_cname_targets: {
        primary: $axel,
        ocsp:    $ocsp
      },
      byo_acm_validation: "deferred_until_cert_request"
    }'
}

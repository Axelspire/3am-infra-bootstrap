# bootstrap-dns-instructions.inc.sh — shared DNS instruction/formula helpers.
# Sourced by customer-org-setup.sh and single-account-setup.sh so the
# customer-facing DNS hand-off is emitted identically from both variants.
#
# These helpers only compute deterministic NAMES/FORMULAS from customer_id +
# region + env. They NEVER create DNS records:
#   - the region-qualified infra FQDNs (api|ocsp|comms.<region>.<cid>.<env>.3amops.com)
#     are created in the customer's 3amops zone by the in-account TF at deploy;
#   - the platform 3am.global vanity names are created MANUALLY by AxelSpire in
#     Cloudflare (automation is future work) and CNAME to the infra FQDNs;
#   - the customer BYO CNAMEs point at the 3amops infra FQDNs (NOT 3am.global)
#     so BYO works even before/without any 3am.global name existing.
# ACM validation CNAMEs for BYO do not exist yet at bootstrap time (they appear
# only after a certificate is requested). See 3AM_ARCHITECTURE.md.
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

# --- non-regional (account-scoped) infra names, optional policy records ---
#   <label>.<customer_id>.<env>.3amops.com
# Only resolvable when an account-scoped latency/active policy record is
# published; a valid alternate BYO target when you want region-failover handled
# on our side instead of pinning BYO to one region.
_dns_infra_fqdn_flat () {
  local label="$1" cid="${2:-${CUSTOMER_ID}}" env="${3:-$(dns_env)}"
  echo "${label}.${cid}.${env}.3amops.com"
}
dns_infra_api_fqdn_flat  () { _dns_infra_fqdn_flat api  "$@"; }
dns_infra_ocsp_fqdn_flat () { _dns_infra_fqdn_flat ocsp "$@"; }

# --- customer-facing human block ---
print_dns_instructions_human () {
  local env; env="$(dns_env)"
  local axel ocsp comms api_t ocsp_t comms_t api_flat ocsp_flat
  axel="$(dns_public_axel_fqdn)"
  ocsp="$(dns_public_ocsp_fqdn)"
  comms="$(dns_public_comms_fqdn)"
  api_t="$(dns_infra_api_fqdn)"
  ocsp_t="$(dns_infra_ocsp_fqdn)"
  comms_t="$(dns_infra_comms_fqdn)"
  api_flat="$(dns_infra_api_fqdn_flat)"
  ocsp_flat="$(dns_infra_ocsp_fqdn_flat)"

  cat <<EOF

  Region-qualified infra targets (created in your 3amops zone by deploy):
    api   : ${api_t}
    ocsp  : ${ocsp_t}
    comms : ${comms_t}

  DNS (platform vanity names — created MANUALLY by AxelSpire in Cloudflare;
       3am.global automation is future work. Each CNAMEs to the infra target):
    primary : ${axel}   ->  ${api_t}
    ocsp    : ${ocsp}   ->  ${ocsp_t}
    comms   : ${comms}  ->  ${comms_t}

  DNS (optional BYO — customer creates CNAMEs once, then we renew forever):
    Point your FQDNs at the 3amops infra targets above. The region-qualified
    target is shown; the non-regional api|ocsp.${CUSTOMER_ID}.${env}.3amops.com
    is equally valid once an account-level policy record is published.
    ${BYO_PRIMARY_FQDN:-<your-primary-fqdn>}  CNAME  ${api_t}.
    ${BYO_OCSP_FQDN:-<your-ocsp-fqdn>}     CNAME  ${ocsp_t}.
    # non-regional alt:  ${api_flat}. / ${ocsp_flat}.
    # ACM validation CNAMEs: provided after cert request (onboard / dns-activate)
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
    --arg api_flat    "$(dns_infra_api_fqdn_flat)" \
    --arg ocsp_flat   "$(dns_infra_ocsp_fqdn_flat)" \
    '{
      env: $env,
      platform: {
        provisioning: "manual_cloudflare",
        primary_fqdn:   $axel,
        ocsp_fqdn:      $ocsp,
        comms_fqdn:     $comms,
        primary_target: $api_infra,
        ocsp_target:    $ocsp_infra,
        comms_target:   $comms_infra
      },
      infra: {
        api_fqdn:   $api_infra,
        ocsp_fqdn:  $ocsp_infra,
        comms_fqdn: $comms_infra
      },
      byo_traffic_cname_targets: {
        primary:             $api_infra,
        ocsp:                $ocsp_infra,
        primary_nonregional: $api_flat,
        ocsp_nonregional:    $ocsp_flat
      },
      byo_acm_validation: "deferred_until_cert_request"
    }'
}

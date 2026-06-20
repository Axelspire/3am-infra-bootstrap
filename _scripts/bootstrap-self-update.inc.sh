# bootstrap-self-update.inc.sh — shared curl-and-run self-update for bootstrap scripts.
# Sourced by customer-org-setup.sh and single-account-setup.sh.
#
# Expects the caller to define:
#   BOOTSTRAP_VERSION, BOOTSTRAP_VARIANT, BOOTSTRAP_SCRIPT_NAME
#   BOOTSTRAP_REPO (optional), BOOTSTRAP_GIT_REF (optional), SKIP_SELF_UPDATE (optional)
# Sets BOOTSTRAP_SCRIPT_PATH before calling bootstrap_maybe_self_update.

bootstrap_su_log () {
  echo "[$(date -u +%H:%M:%SZ)] bootstrap-self-update: $*" >&2
}

bootstrap_su_extract () {
  local file="$1" var="$2"
  grep -m1 "^${var}=" "${file}" 2>/dev/null \
    | sed -E 's/^[^=]+="([^"]*)".*/\1/' \
    || true
}

bootstrap_su_version_sortable () {
  local v="$1" major minor patch rest
  IFS=. read -r major minor patch rest <<< "${v}"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  printf '%05d%05d%05d' "${major}" "${minor}" "${patch}"
}

bootstrap_su_version_gt () {
  local a b
  a="$(bootstrap_su_version_sortable "$1")"
  b="$(bootstrap_su_version_sortable "$2")"
  # Zero-padded sort keys look octal to [[ -gt ]]; force base-10 (patch 8/9 safe).
  [[ $((10#${a})) -gt $((10#${b})) ]]
}

bootstrap_su_remote_url () {
  local repo="${BOOTSTRAP_REPO:-Axelspire/3am-infra-bootstrap}"
  local ref="${BOOTSTRAP_GIT_REF:-main}"
  printf 'https://raw.githubusercontent.com/%s/%s/_scripts/%s' \
    "${repo}" "${ref}" "${BOOTSTRAP_SCRIPT_NAME}"
}

bootstrap_su_wants_skip () {
  case "${SKIP_SELF_UPDATE:-false}" in
    1|true|yes|TRUE|YES) return 0 ;;
  esac
  [[ "${BOOTSTRAP_SELF_UPDATE_REEXEC:-}" == "1" ]] && return 0
  local arg
  for arg in "$@"; do
    [[ "${arg}" == "--skip-self-update" ]] && return 0
  done
  return 1
}

bootstrap_su_resolve_install_path () {
  local candidate="${BOOTSTRAP_SCRIPT_PATH:-}"
  if [[ -n "${candidate}" && "${candidate}" != "-" && -f "${candidate}" ]]; then
    echo "$(cd "$(dirname "${candidate}")" && pwd)/$(basename "${candidate}")"
    return 0
  fi
  printf '%s/%s' "${HOME}" "${BOOTSTRAP_SCRIPT_NAME}"
}

bootstrap_maybe_self_update () {
  bootstrap_su_wants_skip "$@" && return 0

  command -v curl >/dev/null 2>&1 \
    || { bootstrap_su_log "curl not found; continuing with local ${BOOTSTRAP_VERSION}"; return 0; }

  local url tmp remote_version remote_variant install_path
  url="$(bootstrap_su_remote_url)"
  tmp="$(mktemp)"

  if ! curl -fsSL --connect-timeout 10 --max-time 60 "${url}" -o "${tmp}" 2>/dev/null; then
    bootstrap_su_log "could not fetch ${url}; continuing with local ${BOOTSTRAP_VERSION}"
    rm -f "${tmp}"
    return 0
  fi

  if ! head -1 "${tmp}" | grep -q '^#!/usr/bin/env bash'; then
    bootstrap_su_log "remote script at ${url} does not look like a bootstrap script; skipping"
    rm -f "${tmp}"
    return 0
  fi

  remote_version="$(bootstrap_su_extract "${tmp}" BOOTSTRAP_VERSION)"
  remote_variant="$(bootstrap_su_extract "${tmp}" BOOTSTRAP_VARIANT)"

  if [[ -z "${remote_version}" ]]; then
    bootstrap_su_log "remote script has no BOOTSTRAP_VERSION; skipping"
    rm -f "${tmp}"
    return 0
  fi

  if [[ -n "${remote_variant}" && "${remote_variant}" != "${BOOTSTRAP_VARIANT}" ]]; then
    bootstrap_su_log "remote variant '${remote_variant}' != local '${BOOTSTRAP_VARIANT}'; skipping"
    rm -f "${tmp}"
    return 0
  fi

  if bootstrap_su_version_gt "${remote_version}" "${BOOTSTRAP_VERSION}"; then
    install_path="$(bootstrap_su_resolve_install_path)"
    bootstrap_su_log "upgrading ${BOOTSTRAP_VERSION} -> ${remote_version} (${BOOTSTRAP_VARIANT}); installing ${install_path} and re-running"
    cp "${tmp}" "${install_path}"
    chmod +x "${install_path}"
    export BOOTSTRAP_SELF_UPDATE_REEXEC=1
    exec /usr/bin/env bash "${install_path}" "$@"
  fi

  bootstrap_su_log "local ${BOOTSTRAP_VERSION} is current (remote ${remote_version} on ${BOOTSTRAP_GIT_REF:-main})"
  rm -f "${tmp}"
  return 0
}

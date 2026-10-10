#!/usr/bin/env bash
# Copyright (c) 2026 Axelspire Inc. All rights reserved.
# Proprietary. Unauthorized use prohibited. support3am@axelspire.com

# Create or update public GitHub gists for the two customer bootstrap scripts.
# Gists must be owned by the bot user in .github/gist-manifest.json "owner"
# (default: 3am-gists). GitHub orgs cannot own gists.
#
# Requires a classic PAT for that bot user with the `gist` scope in
# GH_TOKEN / GITHUB_TOKEN (Actions: repo secret BOOTSTRAP_GIST_TOKEN).
# The default Actions GITHUB_TOKEN cannot manage gists.
#
# Usage (from repo root):
#   ./_scripts/sync-bootstrap-gists.sh
#   ./_scripts/sync-bootstrap-gists.sh --dry-run
#
# Updates .github/gist-manifest.json when a new gist is created.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${REPO_ROOT}/.github/gist-manifest.json"
DRY_RUN=0
PUBLIC=1

usage () {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --secret) PUBLIC=0; shift ;;
    --public) PUBLIC=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 1; }
[[ -f "${MANIFEST}" ]] || { echo "error: missing ${MANIFEST}" >&2; exit 1; }

EXPECTED_OWNER="$(jq -r '.owner // "3am-gists"' "${MANIFEST}")"

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "${TOKEN}" && "${DRY_RUN}" -eq 0 ]]; then
  echo "error: GH_TOKEN or GITHUB_TOKEN required (gist scope, user ${EXPECTED_OWNER})" >&2
  exit 1
fi
[[ -n "${TOKEN}" ]] && export GH_TOKEN="${TOKEN}"

if [[ "${DRY_RUN}" -eq 0 ]]; then
  token_user="$(gh api user -q .login)"
  if [[ "${token_user}" != "${EXPECTED_OWNER}" ]]; then
    echo "error: BOOTSTRAP_GIST_TOKEN / GH_TOKEN authenticates as '${token_user}', expected '${EXPECTED_OWNER}'" >&2
    echo "Create gists under the ${EXPECTED_OWNER} bot user (GitHub orgs cannot own gists)." >&2
    exit 1
  fi
  echo "Authenticated as ${token_user} (gist owner)"
fi

manifest_changed=0
tmp="$(mktemp)"
# Drop the top-level owner key from the working copy of per-script entries.
jq 'del(.owner)' "${MANIFEST}" > "${tmp}"
trap 'rm -f "${tmp}" "${tmp}.new"' EXIT

keys="$(jq -r 'keys[]' "${tmp}")"
while IFS= read -r key; do
  [[ -n "${key}" ]] || continue
  source_rel="$(jq -r --arg k "${key}" '.[$k].source' "${tmp}")"
  filename="$(jq -r --arg k "${key}" '.[$k].filename' "${tmp}")"
  description="$(jq -r --arg k "${key}" '.[$k].description' "${tmp}")"
  gist_id="$(jq -r --arg k "${key}" '.[$k].gist_id // ""' "${tmp}")"
  source_path="${REPO_ROOT}/${source_rel}"
  [[ -f "${source_path}" ]] || { echo "error: missing source ${source_path}" >&2; exit 1; }

  files_json="$(jq -n --arg fn "${filename}" --rawfile body "${source_path}" \
    '{($fn): {content: $body}}')"

  if [[ -z "${gist_id}" || "${gist_id}" == "null" ]]; then
    echo "Creating gist for ${filename}..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "[dry-run] would create public=${PUBLIC} gist: ${description}"
      continue
    fi
    if [[ "${PUBLIC}" -eq 1 ]]; then
      resp="$(jq -n \
        --arg desc "${description}" \
        --argjson files "${files_json}" \
        '{description:$desc, public:true, files:$files}')"
    else
      resp="$(jq -n \
        --arg desc "${description}" \
        --argjson files "${files_json}" \
        '{description:$desc, public:false, files:$files}')"
    fi
    created="$(echo "${resp}" | gh api -X POST /gists --input -)"
    new_id="$(echo "${created}" | jq -r .id)"
    html_url="$(echo "${created}" | jq -r .html_url)"
    [[ -n "${new_id}" && "${new_id}" != "null" ]] || {
      echo "error: create failed for ${filename}" >&2
      echo "${created}" >&2
      exit 1
    }
    jq --arg k "${key}" --arg id "${new_id}" '.[$k].gist_id = $id' "${tmp}" > "${tmp}.new"
    mv "${tmp}.new" "${tmp}"
    manifest_changed=1
    echo "Created ${filename} → ${html_url} (${new_id})"
  else
    echo "Updating gist ${gist_id} (${filename})..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "[dry-run] would PATCH gist ${gist_id}"
      continue
    fi
    resp="$(jq -n \
      --arg desc "${description}" \
      --argjson files "${files_json}" \
      '{description:$desc, files:$files}')"
    updated="$(echo "${resp}" | gh api -X PATCH "/gists/${gist_id}" --input -)"
    html_url="$(echo "${updated}" | jq -r .html_url)"
    echo "Updated ${filename} → ${html_url}"
  fi
done <<< "${keys}"

if [[ "${manifest_changed}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
  jq --arg owner "${EXPECTED_OWNER}" '{owner: $owner} + .' "${tmp}" > "${MANIFEST}"
  echo "Wrote new gist ids to ${MANIFEST} (owner=${EXPECTED_OWNER})"
fi

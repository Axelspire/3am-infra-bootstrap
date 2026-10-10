#!/usr/bin/env bash
# Copyright (c) 2026 Axelspire Inc. All rights reserved.
# Proprietary. Unauthorized use prohibited. support3am@axelspire.com

# Create or update public GitHub gists for the two customer bootstrap scripts.
# Requires a token with the `gist` scope in GITHUB_TOKEN / GH_TOKEN
# (GITHUB_TOKEN from Actions cannot manage gists — use a classic PAT secret).
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
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
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

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "${TOKEN}" && "${DRY_RUN}" -eq 0 ]]; then
  echo "error: GH_TOKEN or GITHUB_TOKEN required (gist scope)" >&2
  exit 1
fi
[[ -n "${TOKEN}" ]] && export GH_TOKEN="${TOKEN}"

manifest_changed=0
tmp="$(mktemp)"
cp "${MANIFEST}" "${tmp}"
trap 'rm -f "${tmp}" "${tmp}.new"' EXIT

keys="$(jq -r 'keys[]' "${MANIFEST}")"
while IFS= read -r key; do
  [[ -n "${key}" ]] || continue
  source_rel="$(jq -r --arg k "${key}" '.[$k].source' "${MANIFEST}")"
  filename="$(jq -r --arg k "${key}" '.[$k].filename' "${MANIFEST}")"
  description="$(jq -r --arg k "${key}" '.[$k].description' "${MANIFEST}")"
  gist_id="$(jq -r --arg k "${key}" '.[$k].gist_id // ""' "${MANIFEST}")"
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
  cp "${tmp}" "${MANIFEST}"
  echo "Wrote new gist ids to ${MANIFEST}"
fi

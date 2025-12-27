#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Destroys a cluster using openshift-install.
You can also set CLUSTER=<cluster> instead of passing an argument.

Optional env:
  SKIP_CONFIRM     If set to 1/true, skip the confirmation prompt
  CLEAN_INSTALLER  If set to 1/true, remove installer dir after destroy
USAGE
}

CLUSTER="${1:-${CLUSTER:-}}"
if [[ -z "${CLUSTER}" ]]; then
  usage
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cluster_dir="${repo_root}/clusters/${CLUSTER}"
installer_dir="${cluster_dir}/.work/installer"

PREFLIGHT_SKIP_SECRETS=1 "${script_dir}/preflight.sh" "${CLUSTER}"

if [[ "${SKIP_CONFIRM:-}" != "1" && "${SKIP_CONFIRM:-}" != "true" ]]; then
  printf "Type the cluster name (%s) to confirm destroy: " "${CLUSTER}"
  read -r confirm
  if [[ "${confirm}" != "${CLUSTER}" ]]; then
    fail "Confirmation mismatch"
  fi
fi

[[ -d "${installer_dir}" ]] || fail "Missing installer dir: ${installer_dir}"
[[ -f "${installer_dir}/metadata.json" ]] || fail "Missing metadata.json in ${installer_dir}"

log "Running openshift-install destroy cluster"
openshift-install destroy cluster --dir "${installer_dir}"

if [[ "${CLEAN_INSTALLER:-}" == "1" || "${CLEAN_INSTALLER:-}" == "true" ]]; then
  rm -rf "${installer_dir}"
  log "Removed installer dir: ${installer_dir}"
fi

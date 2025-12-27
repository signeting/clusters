#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Creates a cluster using openshift-install.
You can also set CLUSTER=<cluster> instead of passing an argument.

Optional env:
  ALLOW_INSTALLER_REUSE   If set to 1/true, reuse a non-empty installer dir
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
work_dir="${cluster_dir}/.work"
installer_dir="${work_dir}/installer"

"${script_dir}/preflight.sh" "${CLUSTER}"
"${script_dir}/render-install-config.sh" "${CLUSTER}"

if [[ -d "${installer_dir}" && -n "$(ls -A "${installer_dir}")" ]]; then
  if [[ "${ALLOW_INSTALLER_REUSE:-}" != "1" && "${ALLOW_INSTALLER_REUSE:-}" != "true" ]]; then
    fail "Installer dir not empty: ${installer_dir} (set ALLOW_INSTALLER_REUSE=1 to reuse)"
  fi
fi

mkdir -p "${installer_dir}"
cp "${work_dir}/install-config.yaml" "${installer_dir}/install-config.yaml"

log "Running openshift-install create cluster"
openshift-install create cluster --dir "${installer_dir}"

kubeconfig_src="${installer_dir}/auth/kubeconfig"
kubeconfig_dst="${work_dir}/kubeconfig"
[[ -f "${kubeconfig_src}" ]] || fail "Missing kubeconfig at ${kubeconfig_src}"
install -m 600 "${kubeconfig_src}" "${kubeconfig_dst}"

log "Cluster create complete. Kubeconfig: ${kubeconfig_dst}"

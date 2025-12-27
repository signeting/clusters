#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Validates clusters/<cluster>/cluster.yaml against schemas/cluster.schema.json.
You can also set CLUSTER=<cluster> instead of passing an argument.
USAGE
}

CLUSTER="${1:-${CLUSTER:-}}"
if [[ -z "${CLUSTER}" ]]; then
  usage
  exit 2
fi

cluster_yaml="clusters/${CLUSTER}/cluster.yaml"
schema="schemas/cluster.schema.json"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
tools_bin="${TOOLS_BIN:-${repo_root}/.tools/bin}"
jv_bin="${JV_BIN:-}"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"
[[ -f "${schema}" ]] || fail "Missing ${schema}"

command -v yq >/dev/null 2>&1 || fail "yq is required"
if [[ -z "${jv_bin}" ]]; then
  if command -v jv >/dev/null 2>&1; then
    jv_bin="$(command -v jv)"
  else
    TOOLS_BIN="${tools_bin}" "${script_dir}/ensure-jv.sh"
    jv_bin="${tools_bin}/jv"
  fi
fi

[[ -x "${jv_bin}" ]] || fail "jv not found; install with 'go install github.com/santhosh-tekuri/jsonschema/v5/cmd/jv@latest'"

tmp_json="$(mktemp)"
trap 'rm -f "${tmp_json}"' EXIT
yq -o=json '.' "${cluster_yaml}" > "${tmp_json}"

if ! "${jv_bin}" --output basic "${schema}" "${tmp_json}"; then
  exit 1
fi

echo "OK: cluster.yaml is valid"

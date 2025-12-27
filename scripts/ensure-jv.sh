#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

tools_bin="${TOOLS_BIN:-${repo_root}/.tools/bin}"
jv_bin="${tools_bin}/jv"
jv_version="${JV_VERSION:-v5.3.1}"

if [[ -x "${jv_bin}" ]]; then
  log "Using existing jv at ${jv_bin}"
  exit 0
fi

command -v go >/dev/null 2>&1 || fail "go is required to install jv"

mkdir -p "${tools_bin}"
log "Installing jv ${jv_version} into ${tools_bin}"
GOBIN="${tools_bin}" go install "github.com/santhosh-tekuri/jsonschema/v5/cmd/jv@${jv_version}"

[[ -x "${jv_bin}" ]] || fail "jv install failed; ${jv_bin} not found"

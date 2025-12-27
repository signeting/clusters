#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Verifies cluster health (nodes, operators, GitOps namespace if bootstrapped).
You can also set CLUSTER=<cluster> instead of passing an argument.
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
kubeconfig="${work_dir}/kubeconfig"
gitops_trace="${work_dir}/gitops-bootstrap.json"

[[ -f "${kubeconfig}" ]] || fail "Missing kubeconfig at ${kubeconfig}"

required_cmds=(oc jq)
for cmd in "${required_cmds[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
done

export KUBECONFIG="${kubeconfig}"
oc whoami >/dev/null 2>&1 || fail "oc not authenticated (check kubeconfig)"
oc api-resources >/dev/null 2>&1 || fail "oc cannot reach the cluster"

nodes_json="$(oc get nodes -o json)"
total_nodes="$(printf '%s' "${nodes_json}" | jq '.items | length')"
not_ready_nodes="$(printf '%s' "${nodes_json}" | jq -r '.items[] | select((.status.conditions // []) | map(select(.type=="Ready" and .status=="True")) | length == 0) | .metadata.name')"

if [[ "${total_nodes}" -eq 0 ]]; then
  fail "No nodes found"
fi
if [[ -n "${not_ready_nodes}" ]]; then
  fail "Not Ready nodes: ${not_ready_nodes}"
fi

co_json="$(oc get co -o json)"
unavailable_ops="$(printf '%s' "${co_json}" | jq -r '.items[] | select(.status.conditions[] | select(.type=="Available" and .status!="True")) | .metadata.name')"
degraded_ops="$(printf '%s' "${co_json}" | jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name')"

if [[ -n "${unavailable_ops}" ]]; then
  fail "Unavailable clusteroperators: ${unavailable_ops}"
fi
if [[ -n "${degraded_ops}" ]]; then
  fail "Degraded clusteroperators: ${degraded_ops}"
fi

if [[ -f "${gitops_trace}" ]]; then
  oc get ns openshift-gitops >/dev/null 2>&1 || fail "openshift-gitops namespace missing"
  log "GitOps namespace detected"
else
  log "GitOps bootstrap trace not found; skipping namespace check"
fi

log "Verify OK: ${total_nodes} nodes Ready, operators Available"

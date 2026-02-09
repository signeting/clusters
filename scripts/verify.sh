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

has_crd() {
  local crd="$1"
  oc get crd "${crd}" >/dev/null 2>&1
}

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

infra_id="$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || true)"
if [[ -n "${infra_id}" ]]; then
  if ! ms_json="$(oc -n openshift-machine-api get machinesets -o json 2>/dev/null)"; then
    fail "Failed to list MachineSets in openshift-machine-api"
  fi
  mismatched_ms="$(printf '%s' "${ms_json}" | jq -r --arg infra "${infra_id}" '
    .items[]
    | select((.metadata.labels["machine.openshift.io/cluster-api-cluster"] // "") != $infra)
    | "\(.metadata.name) (cluster-api-cluster=\(.metadata.labels["machine.openshift.io/cluster-api-cluster"] // "missing"))"
  ')"
  if [[ -n "${mismatched_ms}" ]]; then
    fail "MachineSets with mismatched infraID (expected ${infra_id}): ${mismatched_ms//$'\n'/ | }"
  fi
fi

if [[ -f "${gitops_trace}" ]]; then
  oc get ns openshift-gitops >/dev/null 2>&1 || fail "openshift-gitops namespace missing"
  log "GitOps namespace detected"

  gitops_repo="$(jq -r '.repo_url // empty' "${gitops_trace}")"
  if [[ -n "${gitops_repo}" ]] && has_crd applications.argoproj.io; then
    if ! apps_json="$(oc -n openshift-gitops get applications.argoproj.io -o json 2>/dev/null)"; then
      fail "Failed to list Argo CD Applications in openshift-gitops"
    fi
    repo_errors="$(printf '%s' "${apps_json}" | jq -r --arg url "${gitops_repo}" '
      .items[]
      | select(
          ((.spec.source.repoURL? // "") == $url) or
          ([.spec.sources[]?.repoURL] | index($url) != null)
        )
      | (.status.conditions // [])
      | map(select(
          (.type // "" | test("ComparisonError|InvalidSpecError|RepoError"; "i")) or
          (.message // "" | test("repository not found|authentication required|permission denied|unable to (connect|list)|no basic auth credentials|status code: (401|403)"; "i"))
        ))
      | .[]
      | "\(.type): \(.message)"
    ' 2>/dev/null || true)"
    if [[ -n "${repo_errors}" ]]; then
      fail "Argo CD repo access errors for ${gitops_repo}: ${repo_errors//$'\n'/ | }"
    fi
  fi

  if has_crd vaultstaticsecrets.secrets.hashicorp.com; then
    if ! vss_json="$(oc get vaultstaticsecrets.secrets.hashicorp.com -A -o json 2>/dev/null)"; then
      fail "Failed to list VaultStaticSecret resources"
    fi
    vss_errors="$(printf '%s' "${vss_json}" | jq -r '
      .items[]
      | . as $vss
      | ($vss.status.conditions // [])[]
      | select((.type=="SecretSynced" or .type=="Ready") and (.status!="True"))
      | "\($vss.metadata.namespace)/\($vss.metadata.name): \(.type)=\(.status) \(.message // "")"
    ' 2>/dev/null || true)"
    if [[ -n "${vss_errors}" ]]; then
      fail "VaultStaticSecret sync failures (configure Vault k8s auth via 'make vault-k8s-auth CLUSTER=${CLUSTER}' if you see auth/kubernetes/login 403): ${vss_errors//$'\n'/ | }"
    fi
  fi
else
  log "GitOps bootstrap trace not found; skipping namespace check"
fi

log "Verify OK: ${total_nodes} nodes Ready, operators Available"

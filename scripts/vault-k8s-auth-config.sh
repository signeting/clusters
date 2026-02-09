#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Configures an external Vault Kubernetes auth mount for this cluster (kubernetes_host, CA, token_reviewer_jwt).

This is required for the GitOps repo's Vault integration (VCO/VSO) to work on freshly-created clusters.

You can also set CLUSTER=<cluster> instead of passing an argument.

Required env:
  VAULT_ADDR            e.g. https://vault.bitiq.io:8200
  VAULT_TOKEN           Vault admin token (do not commit; set in your shell env)

Optional env:
  VAULT_K8S_AUTH_MOUNT  Vault auth mount path (default: kubernetes)
  VAULT_REVIEWER_NAMESPACE  Namespace for reviewer SA/Secret (default: openshift-gitops)
  VAULT_REVIEWER_SERVICEACCOUNT ServiceAccount name (default: vault-token-reviewer)
  VAULT_REVIEWER_SECRET Secret name containing reviewer JWT (default: vault-token-reviewer)
  VAULT_REVIEWER_CLUSTERROLEBINDING ClusterRoleBinding name (default: vault-token-reviewer-auth-delegator)
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

[[ -f "${kubeconfig}" ]] || fail "Missing kubeconfig at ${kubeconfig} (create the cluster first)"

required_cmds=(oc vault)
for cmd in "${required_cmds[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
done

[[ -n "${VAULT_ADDR:-}" ]] || fail "VAULT_ADDR is required"
[[ -n "${VAULT_TOKEN:-}" ]] || fail "VAULT_TOKEN is required"

export KUBECONFIG="${kubeconfig}"
oc whoami >/dev/null 2>&1 || fail "oc not authenticated (check kubeconfig)"
oc api-resources >/dev/null 2>&1 || fail "oc cannot reach the cluster"

mount_path="${VAULT_K8S_AUTH_MOUNT:-kubernetes}"
reviewer_ns="${VAULT_REVIEWER_NAMESPACE:-openshift-gitops}"
reviewer_sa="${VAULT_REVIEWER_SERVICEACCOUNT:-vault-token-reviewer}"
reviewer_secret="${VAULT_REVIEWER_SECRET:-vault-token-reviewer}"
reviewer_crb="${VAULT_REVIEWER_CLUSTERROLEBINDING:-vault-token-reviewer-auth-delegator}"

if ! oc get ns "${reviewer_ns}" >/dev/null 2>&1; then
  oc create ns "${reviewer_ns}" >/dev/null
fi

log "Ensuring token reviewer ServiceAccount/Secret/RBAC in ${reviewer_ns}"
cat <<YAML | oc apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${reviewer_sa}
  namespace: ${reviewer_ns}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${reviewer_secret}
  namespace: ${reviewer_ns}
  annotations:
    kubernetes.io/service-account.name: ${reviewer_sa}
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${reviewer_crb}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: ${reviewer_sa}
    namespace: ${reviewer_ns}
YAML

log "Fetching cluster API server + CA + reviewer JWT (will NOT be printed)"
kube_host="$(oc whoami --show-server 2>/dev/null || true)"
[[ -n "${kube_host}" ]] || fail "Could not determine cluster API server URL (oc whoami --show-server)"

kube_ca=""
attempt=0
while [[ -z "${kube_ca}" && "${attempt}" -lt 30 ]]; do
  kube_ca="$(oc -n "${reviewer_ns}" get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  if [[ -z "${kube_ca}" ]]; then
    sleep 2
    attempt=$((attempt + 1))
  fi
done
[[ -n "${kube_ca}" ]] || fail "Timed out waiting for kube-root-ca.crt in namespace ${reviewer_ns}"

reviewer_jwt=""
attempt=0
while [[ -z "${reviewer_jwt}" && "${attempt}" -lt 30 ]]; do
  reviewer_jwt="$(oc -n "${reviewer_ns}" extract "secret/${reviewer_secret}" --keys=token --to=- 2>/dev/null | tr -d '\n' || true)"
  if [[ -z "${reviewer_jwt}" ]]; then
    sleep 2
    attempt=$((attempt + 1))
  fi
done
[[ -n "${reviewer_jwt}" ]] || fail "Timed out waiting for reviewer JWT in secret ${reviewer_ns}/${reviewer_secret}"

log "Configuring Vault auth mount ${mount_path} for this cluster (will NOT print token/CA)"
vault write "auth/${mount_path}/config" \
  token_reviewer_jwt="${reviewer_jwt}" \
  kubernetes_host="${kube_host}" \
  kubernetes_ca_cert="${kube_ca}" >/dev/null

log "Vault Kubernetes auth configured: VAULT_ADDR=${VAULT_ADDR}, mount=${mount_path}, cluster=${CLUSTER}"

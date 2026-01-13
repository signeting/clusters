#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Bootstraps GitOps for the given cluster.
You can also set CLUSTER=<cluster> instead of passing an argument.

Optional env:
  GITOPS_REUSE_SRC   If set to 1/true, reuse existing .work/gitops-src
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
cluster_yaml="${cluster_dir}/cluster.yaml"
work_dir="${cluster_dir}/.work"
kubeconfig="${work_dir}/kubeconfig"
gitops_dir="${work_dir}/gitops-src"
trace_file="${work_dir}/gitops-bootstrap.json"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"
[[ -f "${kubeconfig}" ]] || fail "Missing kubeconfig at ${kubeconfig}"

required_cmds=(git oc helm jq yq)
for cmd in "${required_cmds[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
done

"${script_dir}/validate.sh" "${CLUSTER}"

cluster_name="$(yq -r '.name' "${cluster_yaml}")"
base_domain="$(yq -r '.dns.base_domain' "${cluster_yaml}")"
gitops_env="$(yq -r '.gitops.env' "${cluster_yaml}")"
gitops_repo="$(yq -r '.gitops.repo_url' "${cluster_yaml}")"
gitops_ref="$(yq -r '.gitops.repo_ref' "${cluster_yaml}")"

apps_base_domain="apps.${cluster_name}.${base_domain}"

mkdir -p "${work_dir}"

if [[ -d "${gitops_dir}" ]]; then
  if [[ "${GITOPS_REUSE_SRC:-}" != "1" && "${GITOPS_REUSE_SRC:-}" != "true" ]]; then
    fail "Existing gitops-src found at ${gitops_dir} (set GITOPS_REUSE_SRC=1 to reuse)"
  fi
  if [[ -n "$(ls -A "${gitops_dir}")" && ! -d "${gitops_dir}/.git" ]]; then
    fail "gitops-src exists but is not a git repo: ${gitops_dir}"
  fi
  if [[ -n "$(git -C "${gitops_dir}" status --porcelain)" ]]; then
    fail "gitops-src has uncommitted changes: ${gitops_dir}"
  fi
else
  git clone "${gitops_repo}" "${gitops_dir}"
fi

git -C "${gitops_dir}" fetch --tags origin >/dev/null
if ! git -C "${gitops_dir}" checkout "${gitops_ref}" >/dev/null 2>&1; then
  git -C "${gitops_dir}" fetch origin "${gitops_ref}" >/dev/null 2>&1 || true
  git -C "${gitops_dir}" checkout "${gitops_ref}"
fi

git_sha="$(git -C "${gitops_dir}" rev-parse HEAD)"
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

wait_for_crd() {
  local crd="$1"
  local timeout_seconds="${2:-600}"
  local waited=0
  while (( waited < timeout_seconds )); do
    if oc get crd "${crd}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

wait_for_subscription_csv() {
  local namespace="$1"
  local subscription="$2"
  local timeout_seconds="${3:-900}"
  local waited=0
  while (( waited < timeout_seconds )); do
    local current_csv
    current_csv="$(oc -n "${namespace}" get subscription "${subscription}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)"
    if [[ -n "${current_csv}" ]]; then
      local phase
      phase="$(oc -n "${namespace}" get csv "${current_csv}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "${phase}" == "Succeeded" ]]; then
        return 0
      fi
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

ensure_namespace() {
  local namespace="$1"
  if ! oc get ns "${namespace}" >/dev/null 2>&1; then
    oc create ns "${namespace}" >/dev/null
  fi
}

wait_for_argocd_available() {
  local namespace="$1"
  local name="$2"
  local timeout_seconds="${3:-900}"
  local waited=0
  while (( waited < timeout_seconds )); do
    local phase
    phase="$(oc -n "${namespace}" get argocd "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Available" ]]; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

ensure_gitops_operator_and_argocd_crd() {
  local values_file="${gitops_dir}/charts/bootstrap-operators/values.yaml"
  if [[ ! -f "${values_file}" ]]; then
    log "WARN: Missing ${values_file}; skipping GitOps operator preflight"
    return 0
  fi

  local gitops_sub_name gitops_sub_channel gitops_sub_source gitops_sub_source_ns
  local gitops_sub_install_ns gitops_sub_approval gitops_sub_starting_csv gitops_disable_default
  local argo_create argo_name argo_ns

  gitops_sub_name="$(yq -r '.operators.gitops.name' "${values_file}")"
  gitops_sub_channel="$(yq -r '.operators.gitops.channel' "${values_file}")"
  gitops_sub_source="$(yq -r '.operators.gitops.source' "${values_file}")"
  gitops_sub_source_ns="$(yq -r '.operators.gitops.sourceNamespace' "${values_file}")"
  gitops_sub_install_ns="$(yq -r '.operators.gitops.installNamespace' "${values_file}")"
  gitops_sub_approval="$(yq -r '.operators.gitops.approval' "${values_file}")"
  gitops_sub_starting_csv="$(yq -r '.operators.gitops.startingCSV // \"\"' "${values_file}")"
  gitops_disable_default="$(yq -r '.operators.gitops.disableDefaultInstance // false' "${values_file}")"

  argo_create="$(yq -r '.argoInstance.create // false' "${values_file}")"
  argo_name="$(yq -r '.argoInstance.name // \"openshift-gitops\"' "${values_file}")"
  argo_ns="$(yq -r '.argoInstance.namespace // \"openshift-gitops\"' "${values_file}")"

  export KUBECONFIG="${kubeconfig}"
  oc whoami >/dev/null 2>&1 || fail "oc not authenticated (check kubeconfig)"
  oc api-resources >/dev/null 2>&1 || fail "oc cannot reach the cluster"

  ensure_namespace "${argo_ns}"

  if ! oc get crd argocds.argoproj.io >/dev/null 2>&1; then
    log "ArgoCD CRD missing; pre-installing ${gitops_sub_name} Subscription to avoid Helm/CRD race"

    cat <<YAML | oc apply -f - >/dev/null
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${gitops_sub_name}
  namespace: ${gitops_sub_install_ns}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: bootstrap-operators
    meta.helm.sh/release-namespace: openshift-operators
spec:
  channel: ${gitops_sub_channel}
  name: ${gitops_sub_name}
  source: ${gitops_sub_source}
  sourceNamespace: ${gitops_sub_source_ns}
  installPlanApproval: ${gitops_sub_approval}
YAML

    if [[ -n "${gitops_sub_starting_csv}" ]]; then
      oc -n "${gitops_sub_install_ns}" patch subscription "${gitops_sub_name}" --type merge \
        -p "{\"spec\":{\"startingCSV\":\"${gitops_sub_starting_csv}\"}}" >/dev/null
    fi

    if [[ "${gitops_disable_default}" == "true" ]]; then
      oc -n "${gitops_sub_install_ns}" patch subscription "${gitops_sub_name}" --type merge \
        -p '{"spec":{"config":{"env":[{"name":"DISABLE_DEFAULT_ARGOCD_INSTANCE","value":"true"}]}}}' >/dev/null
    fi

    if ! wait_for_subscription_csv "${gitops_sub_install_ns}" "${gitops_sub_name}" 1200; then
      fail "Timed out waiting for Subscription ${gitops_sub_name} in namespace ${gitops_sub_install_ns}"
    fi

    if ! wait_for_crd argocds.argoproj.io 1200; then
      fail "Timed out waiting for CRD argocds.argoproj.io"
    fi
  fi

  if [[ "${argo_create}" == "true" ]]; then
    if ! oc -n "${argo_ns}" get argocd "${argo_name}" >/dev/null 2>&1; then
      log "Creating ArgoCD instance ${argo_ns}/${argo_name} early to avoid Helm wait timeouts"
      cat <<YAML | oc apply -f - >/dev/null
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: ${argo_name}
  namespace: ${argo_ns}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: bootstrap-operators
    meta.helm.sh/release-namespace: openshift-operators
spec:
  server:
    route:
      enabled: true
YAML
    fi

    if ! wait_for_argocd_available "${argo_ns}" "${argo_name}" 1200; then
      fail "Timed out waiting for ArgoCD ${argo_ns}/${argo_name} to become Available"
    fi
  fi
}

ensure_gitops_operator_and_argocd_crd

log "Running gitops bootstrap (ENV=${gitops_env}, BASE_DOMAIN=${apps_base_domain})"
(
  cd "${gitops_dir}"
  KUBECONFIG="${kubeconfig}" \
    ENV="${gitops_env}" \
    BASE_DOMAIN="${apps_base_domain}" \
    TARGET_REV="${gitops_ref}" \
    GIT_REPO_URL="${gitops_repo}" \
    ./scripts/bootstrap.sh
)

jq -n \
  --arg cluster "${cluster_name}" \
  --arg env "${gitops_env}" \
  --arg base_domain "${apps_base_domain}" \
  --arg repo_url "${gitops_repo}" \
  --arg repo_ref "${gitops_ref}" \
  --arg git_sha "${git_sha}" \
  --arg timestamp "${timestamp}" \
  '{cluster: $cluster, env: $env, base_domain: $base_domain, repo_url: $repo_url, repo_ref: $repo_ref, git_sha: $git_sha, timestamp: $timestamp}' \
  > "${trace_file}"

log "GitOps bootstrap complete. Trace: ${trace_file}"

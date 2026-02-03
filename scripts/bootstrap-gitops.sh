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
  GITOPS_REUSE_SRC   Deprecated (gitops-src is reused automatically if it's a clean git repo)
  GITOPS_REPO_USERNAME   Repo username for Argo CD (required for private repos)
  GITOPS_REPO_PASSWORD   Repo password/PAT for Argo CD (required for private repos)
  GITOPS_REPO_PAT        Alias for GITOPS_REPO_PASSWORD
  GITOPS_REPO_VAULT_PATH Optional Vault KV path for repo creds (default: gitops/github/gitops-repo)
  GITOPS_REPO_SECRET_NAME  Secret name in openshift-gitops (default: gitops-repo)
  GITOPS_REPO_ACCESS_TIMEOUT Seconds to wait for Argo repo access check (default: 180)
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
export KUBECONFIG="${kubeconfig}"

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
  if [[ -d "${gitops_dir}/.git" ]]; then
    if [[ -n "$(git -C "${gitops_dir}" status --porcelain)" ]]; then
      fail "gitops-src has uncommitted changes: ${gitops_dir}"
    fi
    existing_origin="$(git -C "${gitops_dir}" remote get-url origin 2>/dev/null || true)"
    if [[ -n "${existing_origin}" && "${existing_origin}" != "${gitops_repo}" ]]; then
      log "WARN: Updating gitops-src origin from ${existing_origin} to ${gitops_repo}"
      git -C "${gitops_dir}" remote set-url origin "${gitops_repo}"
    fi
  else
    if [[ -n "$(ls -A "${gitops_dir}")" ]]; then
      fail "gitops-src exists but is not a git repo: ${gitops_dir}"
    fi
    git clone "${gitops_repo}" "${gitops_dir}"
  fi
else
  git clone "${gitops_repo}" "${gitops_dir}"
fi

git -C "${gitops_dir}" fetch --tags origin >/dev/null
if ! git -C "${gitops_dir}" checkout "${gitops_ref}" >/dev/null 2>&1; then
  git -C "${gitops_dir}" fetch origin "${gitops_ref}" >/dev/null 2>&1 || true
  git -C "${gitops_dir}" checkout "${gitops_ref}"
fi

# If the ref points to a remote branch, fast-forward to the latest commit.
if git -C "${gitops_dir}" show-ref --verify --quiet "refs/remotes/origin/${gitops_ref}"; then
  git -C "${gitops_dir}" pull --ff-only origin "${gitops_ref}"
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

ensure_subscription_env_var() {
  local namespace="$1"
  local subscription="$2"
  local env_name="$3"
  local env_value="$4"

  local patch_json
  patch_json="$(oc -n "${namespace}" get subscription "${subscription}" -o json | \
    jq -c --arg name "${env_name}" --arg value "${env_value}" \
      '{spec:{config:{env: ((.spec.config.env // []) | map(select(.name != $name)) + [{"name": $name, "value": $value}])}}}')"

  oc -n "${namespace}" patch subscription "${subscription}" --type merge -p "${patch_json}" >/dev/null
}

remove_subscription_env_var() {
  local namespace="$1"
  local subscription="$2"
  local env_name="$3"

  local patch_json
  patch_json="$(oc -n "${namespace}" get subscription "${subscription}" -o json | \
    jq -c --arg name "${env_name}" \
      '{spec:{config:{env: ((.spec.config.env // []) | map(select(.name != $name)))}}}')"

  oc -n "${namespace}" patch subscription "${subscription}" --type merge -p "${patch_json}" >/dev/null
}

wait_for_subscription_deployment_env() {
  local namespace="$1"
  local subscription="$2"
  local env_name="$3"
  local expected_value="$4"
  local timeout_seconds="${5:-900}"
  local waited=0

  while (( waited < timeout_seconds )); do
    local current_csv
    current_csv="$(oc -n "${namespace}" get subscription "${subscription}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)"
    if [[ -n "${current_csv}" ]]; then
      local deploy_name
      deploy_name="$(oc -n "${namespace}" get deploy -l "olm.owner=${current_csv}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "${deploy_name}" ]]; then
        local current_value
        current_value="$(oc -n "${namespace}" get deploy "${deploy_name}" -o json | \
          jq -r --arg env "${env_name}" '.spec.template.spec.containers[].env[]? | select(.name==$env) | .value' | \
          head -n1)"
        if [[ "${current_value}" == "${expected_value}" ]]; then
          return 0
        fi
      fi
    fi

    sleep 5
    waited=$((waited + 5))
  done

  return 1
}

wait_for_subscription_deployment_env_not_value() {
  local namespace="$1"
  local subscription="$2"
  local env_name="$3"
  local not_value="$4"
  local timeout_seconds="${5:-900}"
  local waited=0

  while (( waited < timeout_seconds )); do
    local current_csv
    current_csv="$(oc -n "${namespace}" get subscription "${subscription}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)"
    if [[ -n "${current_csv}" ]]; then
      local deploy_name
      deploy_name="$(oc -n "${namespace}" get deploy -l "olm.owner=${current_csv}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "${deploy_name}" ]]; then
        local current_value
        current_value="$(oc -n "${namespace}" get deploy "${deploy_name}" -o json | \
          jq -r --arg env "${env_name}" '.spec.template.spec.containers[].env[]? | select(.name==$env) | .value' | \
          head -n1)"
        if [[ -z "${current_value}" || "${current_value}" != "${not_value}" ]]; then
          return 0
        fi
      fi
    fi

    sleep 5
    waited=$((waited + 5))
  done

  return 1
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

base64_encode() {
  # Cross-platform: we only need encoding (not decoding). Both GNU coreutils and macOS `base64`
  # emit a trailing newline by default, so strip it.
  printf '%s' "$1" | base64 | tr -d '\n'
}

load_repo_creds_from_vault() {
  if [[ -n "${GITOPS_REPO_USERNAME:-}" && -n "${GITOPS_REPO_PASSWORD:-${GITOPS_REPO_PAT:-}}" ]]; then
    return 0
  fi
  if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_TOKEN:-}" ]]; then
    return 0
  fi
  if ! command -v vault >/dev/null 2>&1; then
    log "WARN: VAULT_ADDR/VAULT_TOKEN set but vault CLI not found; skipping Vault repo creds lookup"
    return 0
  fi

  local vault_path="${GITOPS_REPO_VAULT_PATH:-gitops/github/gitops-repo}"
  local json username password
  if ! json="$(vault kv get -format=json "${vault_path}" 2>/dev/null)"; then
    log "WARN: Unable to read Vault path ${vault_path}; skipping repo creds lookup"
    return 0
  fi

  username="$(printf '%s' "${json}" | jq -r '.data.data.username // empty')"
  password="$(printf '%s' "${json}" | jq -r '.data.data.password // .data.data.token // empty')"
  if [[ -n "${username}" && -n "${password}" ]]; then
    export GITOPS_REPO_USERNAME="${username}"
    export GITOPS_REPO_PASSWORD="${password}"
    log "Loaded Argo repo creds from Vault path ${vault_path}"
  fi
}

ensure_argocd_repo_secret() {
  local repo_url="$1"
  local namespace="openshift-gitops"
  local secret_name="${GITOPS_REPO_SECRET_NAME:-gitops-repo}"
  local username="${GITOPS_REPO_USERNAME:-}"
  local password="${GITOPS_REPO_PASSWORD:-${GITOPS_REPO_PAT:-}}"

  ensure_namespace "${namespace}"

  # If the secret already exists and points at the same repo URL, don't require creds.
  if oc -n "${namespace}" get secret "${secret_name}" >/dev/null 2>&1; then
    local existing_url_b64 expected_url_b64
    existing_url_b64="$(oc -n "${namespace}" get secret "${secret_name}" -o jsonpath='{.data.url}' 2>/dev/null | tr -d '\n' || true)"
    expected_url_b64="$(base64_encode "${repo_url}")"
    if [[ -n "${existing_url_b64}" && "${existing_url_b64}" == "${expected_url_b64}" ]]; then
      log "Argo CD repo secret already exists: ${namespace}/${secret_name}"
      return 0
    fi

    if [[ -z "${username}" || -z "${password}" ]]; then
      log "WARN: Repo secret ${namespace}/${secret_name} exists but does not match ${repo_url}; no GITOPS_REPO_USERNAME/GITOPS_REPO_PASSWORD provided, so it will not be updated."
      return 0
    fi

    log "Updating Argo CD repo secret: ${namespace}/${secret_name}"
  else
    if [[ -z "${username}" || -z "${password}" ]]; then
      log "WARN: No repo credentials provided and ${namespace}/${secret_name} does not exist; Argo CD may not be able to read ${repo_url} if it's private."
      return 0
    fi

    log "Creating Argo CD repo secret: ${namespace}/${secret_name}"
  fi

  cat <<YAML | oc apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${namespace}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  url: ${repo_url}
  username: ${username}
  password: ${password}
YAML
}

check_argocd_repo_access() {
  # Best-effort: only fail if we can positively detect repo access errors for Applications
  # that reference the requested repoURL. This avoids failing on "URL heuristics".
  local repo_url="$1"
  local namespace="openshift-gitops"
  local timeout_seconds="${GITOPS_REPO_ACCESS_TIMEOUT:-180}"
  local waited=0

  if ! oc get crd applications.argoproj.io >/dev/null 2>&1; then
    log "WARN: CRD applications.argoproj.io not found; skipping Argo repo access check"
    return 0
  fi

  while (( waited < timeout_seconds )); do
    local apps_json
    apps_json="$(oc -n "${namespace}" get applications.argoproj.io -o json 2>/dev/null || true)"
    if [[ -z "${apps_json}" ]]; then
      sleep 5
      waited=$((waited + 5))
      continue
    fi

    local app_count
    app_count="$(printf '%s' "${apps_json}" | jq -r --arg url "${repo_url}" '
      [.items[]
        | select(
            ((.spec.source.repoURL? // "") == $url) or
            ([.spec.sources[]?.repoURL] | index($url) != null)
          )
      ] | length
    ' 2>/dev/null || echo 0)"

    if [[ "${app_count}" == "0" ]]; then
      sleep 5
      waited=$((waited + 5))
      continue
    fi

    local repo_errors
    repo_errors="$(printf '%s' "${apps_json}" | jq -r --arg url "${repo_url}" '
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
      fail "Argo CD cannot access repo ${repo_url}. Provide repo credentials (GITOPS_REPO_USERNAME/GITOPS_REPO_PASSWORD) or configure Argo repo creds in openshift-gitops. Errors: ${repo_errors//$'\n'/ | }"
    fi

    # If Argo has started reconciling these Applications (sync status present), treat that as
    # evidence the repo is readable and stop waiting.
    local reconciled
    reconciled="$(printf '%s' "${apps_json}" | jq -r --arg url "${repo_url}" '
      any(
        .items[]
        | select(
            ((.spec.source.repoURL? // "") == $url) or
            ([.spec.sources[]?.repoURL] | index($url) != null)
          );
        ((.status.sync.status? // "") != "") or ((.status.conditions // []) | length > 0)
      )
    ' 2>/dev/null || echo false)"

    if [[ "${reconciled}" == "true" ]]; then
      log "Argo CD repo access check: OK (${app_count} Application(s) reference ${repo_url})"
      return 0
    fi

    sleep 5
    waited=$((waited + 5))
  done

  log "WARN: Argo CD repo access check timed out after ${timeout_seconds}s (no definitive repo error detected); continuing"
  return 0
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
  gitops_sub_starting_csv="$(yq -r '.operators.gitops.startingCSV // ""' "${values_file}")"
  gitops_disable_default="$(yq -r '.operators.gitops.disableDefaultInstance // false' "${values_file}")"

  argo_create="$(yq -r '.argoInstance.create // false' "${values_file}")"
  argo_name="$(yq -r '.argoInstance.name // "openshift-gitops"' "${values_file}")"
  argo_ns="$(yq -r '.argoInstance.namespace // "openshift-gitops"' "${values_file}")"

  export KUBECONFIG="${kubeconfig}"
  oc whoami >/dev/null 2>&1 || fail "oc not authenticated (check kubeconfig)"
  oc api-resources >/dev/null 2>&1 || fail "oc cannot reach the cluster"

  local bootstrap_ops_status_json=""
  if bootstrap_ops_status_json="$(helm -n openshift-operators status bootstrap-operators --output json 2>/dev/null)"; then
    local bootstrap_ops_status
    bootstrap_ops_status="$(printf '%s' "${bootstrap_ops_status_json}" | jq -r '.info.status // ""')"
    if [[ "${bootstrap_ops_status}" != "deployed" ]]; then
      log "bootstrap-operators Helm release exists (status=${bootstrap_ops_status:-unknown}); running GitOps operator preflight"
    fi
  fi

  local want_disable_default_instance="${gitops_disable_default}"

  ensure_namespace "${argo_ns}"

  if ! oc -n "${gitops_sub_install_ns}" get subscription "${gitops_sub_name}" >/dev/null 2>&1; then
    log "Pre-installing ${gitops_sub_name} Subscription to avoid Helm/CRD race"

    local config_block=""
    if [[ "${want_disable_default_instance}" == "true" ]]; then
      config_block=$'  config:\n    env:\n      - name: DISABLE_DEFAULT_ARGOCD_INSTANCE\n        value: "true"\n'
    fi

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
${config_block}
YAML

    if [[ -n "${gitops_sub_starting_csv}" ]]; then
      oc -n "${gitops_sub_install_ns}" patch subscription "${gitops_sub_name}" --type merge \
        -p "{\"spec\":{\"startingCSV\":\"${gitops_sub_starting_csv}\"}}" >/dev/null
    fi
  fi

  oc -n "${gitops_sub_install_ns}" patch subscription "${gitops_sub_name}" --type merge \
    -p '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"},"annotations":{"meta.helm.sh/release-name":"bootstrap-operators","meta.helm.sh/release-namespace":"openshift-operators"}}}' >/dev/null

  if [[ "${want_disable_default_instance}" == "true" ]]; then
    ensure_subscription_env_var "${gitops_sub_install_ns}" "${gitops_sub_name}" "DISABLE_DEFAULT_ARGOCD_INSTANCE" "true"
  else
    remove_subscription_env_var "${gitops_sub_install_ns}" "${gitops_sub_name}" "DISABLE_DEFAULT_ARGOCD_INSTANCE"
  fi

  if ! wait_for_subscription_csv "${gitops_sub_install_ns}" "${gitops_sub_name}" 1200; then
    fail "Timed out waiting for Subscription ${gitops_sub_name} in namespace ${gitops_sub_install_ns}"
  fi

  if ! wait_for_crd argocds.argoproj.io 1200; then
    fail "Timed out waiting for CRD argocds.argoproj.io"
  fi

  if [[ "${want_disable_default_instance}" == "true" ]]; then
    if ! wait_for_subscription_deployment_env "${gitops_sub_install_ns}" "${gitops_sub_name}" "DISABLE_DEFAULT_ARGOCD_INSTANCE" "true" 900; then
      fail "Timed out waiting for ${gitops_sub_name} operator deployment to pick up DISABLE_DEFAULT_ARGOCD_INSTANCE=true"
    fi
  else
    if ! wait_for_subscription_deployment_env_not_value "${gitops_sub_install_ns}" "${gitops_sub_name}" "DISABLE_DEFAULT_ARGOCD_INSTANCE" "true" 900; then
      fail "Timed out waiting for ${gitops_sub_name} operator deployment to drop DISABLE_DEFAULT_ARGOCD_INSTANCE=true"
    fi
  fi

  if [[ "${argo_create}" == "true" ]]; then
    if oc -n "${argo_ns}" get argocd "${argo_name}" >/dev/null 2>&1; then
      log "Default ArgoCD ${argo_ns}/${argo_name} detected; patching for Helm adoption"
      oc -n "${argo_ns}" patch argocd "${argo_name}" --type merge \
        -p '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"},"annotations":{"meta.helm.sh/release-name":"bootstrap-operators","meta.helm.sh/release-namespace":"openshift-operators"}}}' >/dev/null

      local desired_argo_spec_json
      desired_argo_spec_json="$(yq -o=json '.argoInstance.spec // {}' "${values_file}")"
      desired_argo_spec_json="$(printf '%s' "${desired_argo_spec_json}" | jq -c '. + {applicationSet:{enabled:true}}')"
      oc -n "${argo_ns}" patch argocd "${argo_name}" --type merge -p "{\"spec\":${desired_argo_spec_json}}" >/dev/null
    fi
  fi
}

ensure_gitops_operator_and_argocd_crd

load_repo_creds_from_vault
ensure_argocd_repo_secret "${gitops_repo}"

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

if oc -n openshift-gitops get argocd openshift-gitops >/dev/null 2>&1; then
  log "Enabling ArgoCD ApplicationSet controller"
  oc -n openshift-gitops patch argocd openshift-gitops --type merge \
    -p '{"spec":{"applicationSet":{"enabled":true}}}' >/dev/null
  oc -n openshift-gitops rollout status deployment/openshift-gitops-applicationset-controller --timeout=10m >/dev/null
fi

check_argocd_repo_access "${gitops_repo}"

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

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

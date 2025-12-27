#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Checks tools, schema, AWS account, and secrets for clusters/<cluster>.
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
cluster_yaml="${cluster_dir}/cluster.yaml"
secrets_dir="${repo_root}/secrets/${CLUSTER}"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"

required_cmds=(aws terraform oc openshift-install helm jq yq go)
for cmd in "${required_cmds[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
done

"${script_dir}/validate.sh" "${CLUSTER}"

name="$(yq -r '.name' "${cluster_yaml}")"
env="$(yq -r '.env' "${cluster_yaml}")"
platform_type="$(yq -r '.platform.type' "${cluster_yaml}")"
account_id="$(yq -r '.platform.account_id' "${cluster_yaml}")"
region="$(yq -r '.platform.region' "${cluster_yaml}")"
zones="$(yq -r '.platform.zones | join(",")' "${cluster_yaml}")"
base_domain="$(yq -r '.dns.base_domain' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"
gitops_env="$(yq -r '.gitops.env' "${cluster_yaml}")"
gitops_repo="$(yq -r '.gitops.repo_url' "${cluster_yaml}")"
gitops_ref="$(yq -r '.gitops.repo_ref' "${cluster_yaml}")"

if [[ "${name}" != "${CLUSTER}" ]]; then
  log "WARN: cluster.yaml name (${name}) does not match directory (${CLUSTER})"
fi

aws_args=()
profile_label="default"
if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
  aws_args+=(--profile "${aws_profile}")
  profile_label="${aws_profile}"
elif [[ -n "${AWS_PROFILE:-}" ]]; then
  profile_label="${AWS_PROFILE}"
fi

identity_json="$(aws "${aws_args[@]}" sts get-caller-identity --output json 2>/dev/null)" || {
  fail "Failed to call aws sts get-caller-identity (profile: ${profile_label})"
}
caller_account="$(printf '%s' "${identity_json}" | jq -r '.Account // empty')"
caller_arn="$(printf '%s' "${identity_json}" | jq -r '.Arn // empty')"

[[ -n "${caller_account}" ]] || fail "Could not read AWS account ID from STS response"
if [[ "${caller_account}" != "${account_id}" ]]; then
  fail "AWS account mismatch: expected ${account_id}, got ${caller_account} (profile: ${profile_label})"
fi

if [[ "${PREFLIGHT_SKIP_SECRETS:-}" != "1" && "${PREFLIGHT_SKIP_SECRETS:-}" != "true" ]]; then
  pull_secret="${secrets_dir}/pull-secret.json"
  ssh_pub="${secrets_dir}/ssh.pub"
  [[ -f "${pull_secret}" ]] || fail "Missing pull secret: ${pull_secret}"
  [[ -f "${ssh_pub}" ]] || fail "Missing SSH public key: ${ssh_pub}"
else
  log "Skipping secrets check (PREFLIGHT_SKIP_SECRETS=1)"
fi

log "Preflight OK"
log "Cluster: ${CLUSTER} (name: ${name}, env: ${env})"
log "Platform: ${platform_type} (account: ${account_id}, region: ${region}, zones: ${zones})"
log "DNS: ${base_domain}"
log "AWS: profile=${profile_label}, caller=${caller_arn}"
log "GitOps: env=${gitops_env}, repo=${gitops_repo}, ref=${gitops_ref}"

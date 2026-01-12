#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Applies Terraform prereqs (DNS/IAM) for the given cluster.
You can also set CLUSTER=<cluster> instead of passing an argument.

Optional env:
  TF_STATE_BUCKET   Override the state bucket name
  TF_STATE_KEY      Override the state key (default: clusters/<cluster>/prereqs.tfstate)
  TF_AUTO_APPROVE   If set to 1/true, runs terraform apply -auto-approve
USAGE
}

CLUSTER="${1:-${CLUSTER:-}}"
if [[ -z "${CLUSTER}" ]]; then
  usage
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
tf_dir="${repo_root}/platforms/aws/terraform/prereqs"
cluster_dir="${repo_root}/clusters/${CLUSTER}"
cluster_yaml="${cluster_dir}/cluster.yaml"
work_dir="${cluster_dir}/.work"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"
[[ -d "${tf_dir}" ]] || fail "Missing ${tf_dir}"

"${script_dir}/preflight.sh" "${CLUSTER}"

account_id="$(yq -r '.platform.account_id' "${cluster_yaml}")"
region="$(yq -r '.platform.region' "${cluster_yaml}")"
cluster_name="$(yq -r '.name' "${cluster_yaml}")"
env_name="$(yq -r '.env' "${cluster_yaml}")"
base_domain="$(yq -r '.dns.base_domain' "${cluster_yaml}")"
hosted_zone_id="$(yq -r '.dns.hosted_zone_id // ""' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"

[[ -n "${account_id}" && "${account_id}" != "null" ]] || fail "platform.account_id not set"
[[ -n "${region}" && "${region}" != "null" ]] || fail "platform.region not set"
[[ -n "${cluster_name}" && "${cluster_name}" != "null" ]] || fail "name not set"
[[ -n "${env_name}" && "${env_name}" != "null" ]] || fail "env not set"
[[ -n "${base_domain}" && "${base_domain}" != "null" ]] || fail "dns.base_domain not set"

state_bucket="${TF_STATE_BUCKET:-signet-clusters-tfstate-${account_id}}"
state_key="${TF_STATE_KEY:-clusters/${CLUSTER}/prereqs.tfstate}"

if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
  export AWS_PROFILE="${aws_profile}"
fi
export AWS_SDK_LOAD_CONFIG=1
log "Using AWS_PROFILE=${AWS_PROFILE:-default} for terraform"

apply_args=()
if [[ "${TF_AUTO_APPROVE:-}" == "1" || "${TF_AUTO_APPROVE:-}" == "true" ]]; then
  apply_args+=(-auto-approve)
fi

log "Initializing terraform (prereqs)"
terraform -chdir="${tf_dir}" init -reconfigure \
  -backend-config="bucket=${state_bucket}" \
  -backend-config="key=${state_key}" \
  -backend-config="region=${region}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

log "Applying terraform (prereqs)"
terraform -chdir="${tf_dir}" apply \
  -var "account_id=${account_id}" \
  -var "region=${region}" \
  -var "cluster_name=${cluster_name}" \
  -var "env=${env_name}" \
  -var "base_domain=${base_domain}" \
  -var "hosted_zone_id=${hosted_zone_id}" \
  "${apply_args[@]}"

mkdir -p "${work_dir}"
terraform -chdir="${tf_dir}" output -json > "${work_dir}/terraform-prereqs.json"

log "Prereqs complete. Outputs written to ${work_dir}/terraform-prereqs.json"

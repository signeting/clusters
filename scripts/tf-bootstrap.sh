#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Bootstraps the Terraform state bucket for the AWS account.
You can also set CLUSTER=<cluster> instead of passing an argument.

Optional env:
  TF_STATE_BUCKET   Override the state bucket name
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
tf_dir="${repo_root}/platforms/aws/terraform/bootstrap"
cluster_yaml="${repo_root}/clusters/${CLUSTER}/cluster.yaml"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"
[[ -d "${tf_dir}" ]] || fail "Missing ${tf_dir}"

"${script_dir}/preflight.sh" "${CLUSTER}"

account_id="$(yq -r '.platform.account_id' "${cluster_yaml}")"
region="$(yq -r '.platform.region' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"

[[ -n "${account_id}" && "${account_id}" != "null" ]] || fail "platform.account_id not set"
[[ -n "${region}" && "${region}" != "null" ]] || fail "platform.region not set"

state_bucket="${TF_STATE_BUCKET:-signet-clusters-tfstate-${account_id}}"

if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
  export AWS_PROFILE="${aws_profile}"
fi
export AWS_SDK_LOAD_CONFIG=1
log "Using AWS_PROFILE=${AWS_PROFILE:-default} for terraform"

apply_args=()
if [[ "${TF_AUTO_APPROVE:-}" == "1" || "${TF_AUTO_APPROVE:-}" == "true" ]]; then
  apply_args+=(-auto-approve)
fi

log "Initializing terraform (bootstrap)"
terraform -chdir="${tf_dir}" init

log "Applying terraform (bootstrap)"
terraform -chdir="${tf_dir}" apply \
  -var "account_id=${account_id}" \
  -var "region=${region}" \
  -var "bucket_name=${state_bucket}" \
  "${apply_args[@]}"

log "Bootstrap complete: bucket=${state_bucket} region=${region}"

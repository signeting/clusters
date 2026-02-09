#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Destroys Terraform prereqs (DNS/IAM) for the given cluster.
You can also set CLUSTER=<cluster> instead of passing an argument.

Safety default: preserves the Route53 hosted zone if it was created by Terraform.
Set DESTROY_HOSTED_ZONE=1 to delete the hosted zone too.

Optional env:
  TF_STATE_BUCKET       Override the state bucket name
  TF_STATE_KEY          Override the state key (default: clusters/<cluster>/prereqs.tfstate)
  TF_AUTO_APPROVE       If set to 1/true, runs terraform destroy -auto-approve
  SKIP_CONFIRM          If set to 1/true, skip the confirmation prompt
  NON_INTERACTIVE       If set to 1/true, skip prompts (implies SKIP_CONFIRM=1 and TF_AUTO_APPROVE=1)
  DESTROY_HOSTED_ZONE   If set to 1/true, allow terraform to delete the hosted zone it created
  PRESERVE_HOSTED_ZONE  If set to 0/false, same as DESTROY_HOSTED_ZONE=1
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

# Terraform prereqs destroy does not depend on openshift-install version; keep account guardrails only.
PREFLIGHT_SKIP_SECRETS=1 \
PREFLIGHT_SKIP_OPENSHIFT_INSTALLER_VERSION_CHECK=1 \
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

skip_confirm="${SKIP_CONFIRM:-}"
destroy_args=()

if [[ "${NON_INTERACTIVE:-}" == "1" || "${NON_INTERACTIVE:-}" == "true" ]]; then
  export TF_IN_AUTOMATION=1
  skip_confirm="1"
  destroy_args+=(-auto-approve)
fi

if [[ "${TF_AUTO_APPROVE:-}" == "1" || "${TF_AUTO_APPROVE:-}" == "true" ]]; then
  destroy_args+=(-auto-approve)
fi

if [[ "${skip_confirm}" != "1" && "${skip_confirm}" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    fail "Refusing to prompt for confirmation in a non-interactive session (set SKIP_CONFIRM=1 or NON_INTERACTIVE=1)"
  fi
  printf "Type the cluster name (%s) to confirm Terraform destroy: " "${CLUSTER}"
  read -r confirm
  if [[ "${confirm}" != "${CLUSTER}" ]]; then
    fail "Confirmation mismatch"
  fi
fi

log "Initializing terraform (prereqs)"
terraform -chdir="${tf_dir}" init -reconfigure \
  -backend-config="bucket=${state_bucket}" \
  -backend-config="key=${state_key}" \
  -backend-config="region=${region}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

preserve_hosted_zone="1"
if [[ "${DESTROY_HOSTED_ZONE:-}" == "1" || "${DESTROY_HOSTED_ZONE:-}" == "true" ]]; then
  preserve_hosted_zone="0"
fi
if [[ "${PRESERVE_HOSTED_ZONE:-}" == "0" || "${PRESERVE_HOSTED_ZONE:-}" == "false" ]]; then
  preserve_hosted_zone="0"
fi

preserved_zone_id=""
if [[ "${preserve_hosted_zone}" == "1" ]]; then
  state_list="$(terraform -chdir="${tf_dir}" state list 2>/dev/null || true)"

  zone_addr=""
  if printf '%s\n' "${state_list}" | grep -q '^aws_route53_zone\\.primary\\[0\\]$'; then
    zone_addr="aws_route53_zone.primary[0]"
  elif printf '%s\n' "${state_list}" | grep -q '^aws_route53_zone\\.primary$'; then
    zone_addr="aws_route53_zone.primary"
  fi

  if [[ -n "${zone_addr}" ]]; then
    zone_state="$(terraform -chdir="${tf_dir}" state show "${zone_addr}" 2>/dev/null || true)"
    preserved_zone_id="$(printf '%s\n' "${zone_state}" | awk -F' = ' '/^zone_id = / {print $2; exit}')"
    if [[ -z "${preserved_zone_id}" ]]; then
      preserved_zone_id="$(printf '%s\n' "${zone_state}" | awk -F' = ' '/^id = / {print $2; exit}')"
    fi

    log "Preserving Route53 hosted zone (detaching from terraform state): ${zone_addr}"
    terraform -chdir="${tf_dir}" state rm "${zone_addr}"
    if [[ -n "${preserved_zone_id}" ]]; then
      log "Hosted zone preserved: ${preserved_zone_id} (${base_domain})"
      log "Tip: set dns.hosted_zone_id: \"${preserved_zone_id}\" in clusters/${CLUSTER}/cluster.yaml if you want to reuse this zone later."
    else
      log "Hosted zone preserved (${base_domain}); could not read hosted zone ID from terraform state."
    fi
  else
    log "No hosted zone resource found in terraform state to preserve."
  fi
fi

log "Destroying terraform (prereqs)"
terraform -chdir="${tf_dir}" destroy \
  -var "account_id=${account_id}" \
  -var "region=${region}" \
  -var "cluster_name=${cluster_name}" \
  -var "env=${env_name}" \
  -var "base_domain=${base_domain}" \
  -var "hosted_zone_id=${hosted_zone_id}" \
  "${destroy_args[@]}"

if [[ -f "${work_dir}/terraform-prereqs.json" ]]; then
  rm -f "${work_dir}/terraform-prereqs.json"
  log "Removed stale terraform outputs: ${work_dir}/terraform-prereqs.json"
fi

log "Terraform prereqs destroy complete."

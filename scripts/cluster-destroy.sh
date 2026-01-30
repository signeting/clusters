#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

get_hosted_zone_json() {
  local zone_id="$1"
  local attempt
  local json

  for attempt in 1 2 3; do
    if json="$(aws route53 get-hosted-zone --id "${zone_id}" --output json)"; then
      printf '%s' "${json}"
      return 0
    fi
    log "WARN: failed to fetch hosted zone ${zone_id} (attempt ${attempt}/3)"
    sleep 2
  done

  return 1
}

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Destroys a cluster using openshift-install.
You can also set CLUSTER=<cluster> instead of passing an argument.

Optional env:
  SKIP_CONFIRM     If set to 1/true, skip the confirmation prompt
  SKIP_CLEANUP_CHECK If set to 1/true, skip the post-destroy AWS cleanup report
  CLEAN_INSTALLER  If set to 1/true, remove installer dir after destroy
  NON_INTERACTIVE  If set to 1/true, skip prompts (implies SKIP_CONFIRM=1)
  OWNED_WAIT_SECONDS            Passed to cleanup-check (default: 900)
  OWNED_WAIT_INTERVAL_SECONDS   Passed to cleanup-check (default: 30)
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
installer_dir="${cluster_dir}/.work/installer"
trace_file="${work_dir}/gitops-bootstrap.json"
kubeconfig="${work_dir}/kubeconfig"

PREFLIGHT_SKIP_SECRETS=1 "${script_dir}/preflight.sh" "${CLUSTER}"

base_domain="$(yq -r '.dns.base_domain' "${cluster_yaml}")"
hosted_zone_id="$(yq -r '.dns.hosted_zone_id // ""' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"
if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
  export AWS_PROFILE="${aws_profile}"
fi
export AWS_SDK_LOAD_CONFIG=1
log "Using AWS_PROFILE=${AWS_PROFILE:-default} for openshift-install"

zone_name_before=""
if [[ -n "${hosted_zone_id}" && "${hosted_zone_id}" != "null" ]]; then
  log "Verifying Route53 hosted zone exists (will NOT be deleted): ${hosted_zone_id}"
  zone_json="$(get_hosted_zone_json "${hosted_zone_id}")" || {
    fail "Failed to read hosted zone ${hosted_zone_id}. openshift-install destroy needs Route53 access to clean up DNS records."
  }
  zone_name_before="$(printf '%s' "${zone_json}" | jq -r '.HostedZone.Name // empty')"
  if [[ -z "${zone_name_before}" ]]; then
    fail "Could not read HostedZone.Name for ${hosted_zone_id}"
  fi
  expected_zone_name="${base_domain}."
  if [[ "${zone_name_before}" != "${expected_zone_name}" ]]; then
    log "WARN: hosted zone name mismatch for ${hosted_zone_id}: expected ${expected_zone_name}, got ${zone_name_before}"
  fi
fi

skip_confirm="${SKIP_CONFIRM:-}"
if [[ "${NON_INTERACTIVE:-}" == "1" || "${NON_INTERACTIVE:-}" == "true" ]]; then
  skip_confirm="1"
fi

if [[ "${skip_confirm}" != "1" && "${skip_confirm}" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    fail "Refusing to prompt for confirmation in a non-interactive session (set SKIP_CONFIRM=1 or NON_INTERACTIVE=1)"
  fi
  printf "Type the cluster name (%s) to confirm destroy: " "${CLUSTER}"
  read -r confirm
  if [[ "${confirm}" != "${CLUSTER}" ]]; then
    fail "Confirmation mismatch"
  fi
fi

[[ -d "${installer_dir}" ]] || fail "Missing installer dir: ${installer_dir}"
[[ -f "${installer_dir}/metadata.json" ]] || fail "Missing metadata.json in ${installer_dir}"
infra_id="$(jq -r '.infraID // empty' "${installer_dir}/metadata.json")"
[[ -n "${infra_id}" ]] || fail "Could not read infraID from ${installer_dir}/metadata.json"
printf '%s' "${infra_id}" > "${work_dir}/infraID"

log "Running openshift-install destroy cluster"
openshift-install destroy cluster --dir "${installer_dir}"

if [[ -n "${hosted_zone_id}" && "${hosted_zone_id}" != "null" ]]; then
  zone_json_after="$(get_hosted_zone_json "${hosted_zone_id}")" || {
    fail "Hosted zone ${hosted_zone_id} is no longer readable after destroy. If this was unintended, verify Route53 immediately."
  }
  zone_name_after="$(printf '%s' "${zone_json_after}" | jq -r '.HostedZone.Name // empty')"
  if [[ -z "${zone_name_after}" ]]; then
    fail "Could not read HostedZone.Name for ${hosted_zone_id} after destroy"
  fi
  if [[ -n "${zone_name_before}" && "${zone_name_after}" != "${zone_name_before}" ]]; then
    fail "Hosted zone name changed unexpectedly for ${hosted_zone_id}: was ${zone_name_before}, now ${zone_name_after}"
  fi
  log "Hosted zone preserved: ${hosted_zone_id} (${zone_name_after})"
fi

if [[ -f "${trace_file}" ]]; then
  rm -f "${trace_file}"
  log "Removed GitOps bootstrap trace: ${trace_file}"
fi

if [[ -f "${kubeconfig}" ]]; then
  rm -f "${kubeconfig}"
  log "Removed kubeconfig: ${kubeconfig}"
fi

if [[ "${SKIP_CLEANUP_CHECK:-}" != "1" && "${SKIP_CLEANUP_CHECK:-}" != "true" ]]; then
  log "Running AWS cleanup check (set SKIP_CLEANUP_CHECK=1 to skip)"
  INFRA_ID="${infra_id}" \
  OWNED_WAIT_SECONDS="${OWNED_WAIT_SECONDS:-900}" \
  OWNED_WAIT_INTERVAL_SECONDS="${OWNED_WAIT_INTERVAL_SECONDS:-30}" \
  "${script_dir}/aws-cleanup-check.sh" "${CLUSTER}"
fi

if [[ "${CLEAN_INSTALLER:-}" == "1" || "${CLEAN_INSTALLER:-}" == "true" ]]; then
  rm -rf "${installer_dir}"
  log "Removed installer dir: ${installer_dir}"
fi

#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

openshift_install_version() {
  # Output like: "openshift-install 4.18.4"
  openshift-install version 2>/dev/null | awk '/^openshift-install[[:space:]]+/ {print $2; exit}'
}

latest_openshift_patch_for_minor() {
  local minor="$1"
  local mirror_base="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
  local html versions

  html="$(curl -fsSL "${mirror_base}")" || return 1
  versions="$(printf '%s' "${html}" \
    | grep -Eo 'href="[0-9]+\.[0-9]+\.[0-9]+/' \
    | sed -E 's/^href="([^"]+)\\/$/\\1/' \
    | grep -E "^${minor}\\.[0-9]+$" \
    | sort -V \
    | tail -n 1)"
  [[ -n "${versions}" ]] || return 1
  printf '%s' "${versions}"
}

latest_openshift_overall() {
  local mirror_base="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
  local html versions

  html="$(curl -fsSL "${mirror_base}")" || return 1
  versions="$(printf '%s' "${html}" \
    | grep -Eo 'href="[0-9]+\.[0-9]+\.[0-9]+/' \
    | sed -E 's/^href="([^"]+)\\/$/\\1/' \
    | sort -V \
    | tail -n 1)"
  [[ -n "${versions}" ]] || return 1
  printf '%s' "${versions}"
}

check_openshift_installer_is_latest() {
  local cluster_yaml="$1"
  local desired_version desired_minor latest_overall latest_overall_minor latest_patch local_installer

  if is_true "${PREFLIGHT_SKIP_OPENSHIFT_INSTALLER_VERSION_CHECK:-}"; then
    log "Skipping openshift-install version check (PREFLIGHT_SKIP_OPENSHIFT_INSTALLER_VERSION_CHECK=1)"
    return 0
  fi

  desired_version="$(yq -r '.openshift.version // ""' "${cluster_yaml}")"
  [[ -n "${desired_version}" && "${desired_version}" != "null" ]] || fail "openshift.version not set in ${cluster_yaml}"

  if [[ "${desired_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    desired_minor="$(printf '%s' "${desired_version}" | awk -F. '{print $1"."$2}')"
  elif [[ "${desired_version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    desired_minor="${desired_version}"
  else
    fail "openshift.version must be X.Y or X.Y.Z (got: ${desired_version})"
  fi

  local_installer="$(openshift_install_version)"
  [[ -n "${local_installer}" ]] || fail "Could not determine openshift-install version (is it installed and on PATH?)"

  latest_overall="$(latest_openshift_overall)" || fail "Could not determine latest OpenShift version from mirror.openshift.com (check network/DNS), or set PREFLIGHT_SKIP_OPENSHIFT_INSTALLER_VERSION_CHECK=1"
  latest_overall_minor="$(printf '%s' "${latest_overall}" | awk -F. '{print $1\".\"$2}')"

  if [[ "${desired_minor}" != "${latest_overall_minor}" ]]; then
    fail "openshift.version (${desired_minor}) is not the latest minor (${latest_overall_minor}). Update ${cluster_yaml} to the latest minor, or set PREFLIGHT_SKIP_OPENSHIFT_INSTALLER_VERSION_CHECK=1"
  fi

  latest_patch="$(latest_openshift_patch_for_minor "${desired_minor}")" || fail "Could not determine latest patch for ${desired_minor} from mirror.openshift.com"

  if [[ "${desired_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${desired_version}" != "${latest_patch}" ]]; then
    fail "openshift.version is pinned to ${desired_version}, but latest patch for ${desired_minor} is ${latest_patch}. Update ${cluster_yaml} or set PREFLIGHT_SKIP_OPENSHIFT_INSTALLER_VERSION_CHECK=1"
  fi

  if [[ "${local_installer}" != "${latest_patch}" ]]; then
    fail "openshift-install is ${local_installer}, but latest for ${desired_minor} is ${latest_patch}. Download the matching openshift-install, or set PREFLIGHT_SKIP_OPENSHIFT_INSTALLER_VERSION_CHECK=1"
  fi

  log "OpenShift installer OK: openshift-install=${local_installer} (latest for ${desired_minor})"
}

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

required_cmds=(aws terraform oc openshift-install helm jq yq go curl)
for cmd in "${required_cmds[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
done

"${script_dir}/validate.sh" "${CLUSTER}"

check_openshift_installer_is_latest "${cluster_yaml}"

name="$(yq -r '.name' "${cluster_yaml}")"
env="$(yq -r '.env' "${cluster_yaml}")"
platform_type="$(yq -r '.platform.type' "${cluster_yaml}")"
account_id="$(yq -r '.platform.account_id' "${cluster_yaml}")"
region="$(yq -r '.platform.region' "${cluster_yaml}")"
zones="$(yq -r '.platform.zones | join(",")' "${cluster_yaml}")"
base_domain="$(yq -r '.dns.base_domain' "${cluster_yaml}")"
control_plane_replicas="$(yq -r '.openshift.control_plane_replicas' "${cluster_yaml}")"
compute_replicas="$(yq -r '.openshift.compute_replicas' "${cluster_yaml}")"
compute_market="$(yq -r '.openshift.compute_market // "on-demand"' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"
cco_mode="$(yq -r '.credentials.cco_mode' "${cluster_yaml}")"
gitops_env="$(yq -r '.gitops.env' "${cluster_yaml}")"
gitops_repo="$(yq -r '.gitops.repo_url' "${cluster_yaml}")"
gitops_ref="$(yq -r '.gitops.repo_ref' "${cluster_yaml}")"

if [[ "${cco_mode}" == "manual-sts" ]]; then
  command -v ccoctl >/dev/null 2>&1 || fail "Missing required tool for manual-sts: ccoctl"
fi

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
log "OpenShift: control_plane_replicas=${control_plane_replicas}, compute_replicas=${compute_replicas}, compute_market=${compute_market}"
log "GitOps: env=${gitops_env}, repo=${gitops_repo}, ref=${gitops_ref}"

if [[ "${compute_market}" == "spot" && "${compute_replicas}" != "0" ]]; then
  log "INFO: compute_market=spot will install with 0 workers; run 'make spot-workers CLUSTER=${CLUSTER}' after cluster-create"
fi

#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Creates AWS STS IAM/OIDC resources and manifests for manual CCO mode.
You can also set CLUSTER=<cluster> instead of passing an argument.

Required env:
  OPENSHIFT_RELEASE_IMAGE   e.g. quay.io/openshift-release-dev/ocp-release:4.20.0-x86_64

Optional env:
  ALLOW_INSTALLER_REUSE        If set to 1/true, reuse a non-empty installer dir
  CCO_DRY_RUN                  If set to 1/true, pass --dry-run to ccoctl
  CCO_CREATE_PRIVATE_S3_BUCKET If set to 1/true, pass --create-private-s3-bucket
  REGISTRY_AUTH_FILE           If set, use this auth file for oc release extract
  SKIP_CONFIRM                 If set to 1/true, skip confirmation prompt
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
installer_dir="${work_dir}/installer"
credreq_dir="${work_dir}/credrequests"
cco_output_dir="${work_dir}/ccoctl"
secrets_dir="${repo_root}/secrets/${CLUSTER}"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"

required_cmds=(oc openshift-install ccoctl jq yq)
for cmd in "${required_cmds[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
done

"${script_dir}/preflight.sh" "${CLUSTER}"

cco_mode="$(yq -r '.credentials.cco_mode' "${cluster_yaml}")"
region="$(yq -r '.platform.region' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"

if [[ "${cco_mode}" != "manual-sts" ]]; then
  fail "credentials.cco_mode must be manual-sts (found: ${cco_mode})"
fi

if [[ -z "${OPENSHIFT_RELEASE_IMAGE:-}" ]]; then
  fail "OPENSHIFT_RELEASE_IMAGE is required (e.g. quay.io/openshift-release-dev/ocp-release:4.20.0-x86_64)"
fi

registry_auth_file="${REGISTRY_AUTH_FILE:-${secrets_dir}/pull-secret.json}"
[[ -f "${registry_auth_file}" ]] || fail "Missing registry auth file at ${registry_auth_file} (set REGISTRY_AUTH_FILE or ensure ${secrets_dir}/pull-secret.json exists)"

profile_label="default"
aws_env=()
if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
  aws_env=(AWS_PROFILE="${aws_profile}")
  profile_label="${aws_profile}"
elif [[ -n "${AWS_PROFILE:-}" ]]; then
  profile_label="${AWS_PROFILE}"
fi

if [[ -d "${installer_dir}" && -n "$(ls -A "${installer_dir}")" ]]; then
  if [[ "${ALLOW_INSTALLER_REUSE:-}" != "1" && "${ALLOW_INSTALLER_REUSE:-}" != "true" ]]; then
    fail "Installer dir not empty: ${installer_dir} (set ALLOW_INSTALLER_REUSE=1 to reuse)"
  fi
fi

"${script_dir}/render-install-config.sh" "${CLUSTER}"
mkdir -p "${installer_dir}"
cp "${work_dir}/install-config.yaml" "${installer_dir}/install-config.yaml"

if [[ "${SKIP_CONFIRM:-}" != "1" && "${SKIP_CONFIRM:-}" != "true" ]]; then
  printf "Type the cluster name (%s) to proceed with STS resource creation: " "${CLUSTER}"
  read -r confirm
  if [[ "${confirm}" != "${CLUSTER}" ]]; then
    fail "Confirmation mismatch"
  fi
fi

log "Generating installer manifests"
openshift-install create manifests --dir "${installer_dir}"

metadata_json="${installer_dir}/metadata.json"
[[ -f "${metadata_json}" ]] || fail "Missing metadata.json at ${metadata_json}"
infra_id="$(jq -r '.infraID // empty' "${metadata_json}")"
[[ -n "${infra_id}" ]] || fail "infraID not found in ${metadata_json}"

log "Extracting CredentialsRequests from release image"
rm -rf "${credreq_dir}"
mkdir -p "${credreq_dir}"
oc adm release extract --credentials-requests --cloud=aws \
  --registry-config "${registry_auth_file}" \
  --to="${credreq_dir}" \
  "${OPENSHIFT_RELEASE_IMAGE}"

ccoctl_args=(
  aws create-all
  --name "${infra_id}"
  --region "${region}"
  --credentials-requests-dir "${credreq_dir}"
  --output-dir "${cco_output_dir}"
)
if [[ "${CCO_DRY_RUN:-}" == "1" || "${CCO_DRY_RUN:-}" == "true" ]]; then
  ccoctl_args+=(--dry-run)
fi
if [[ "${CCO_CREATE_PRIVATE_S3_BUCKET:-}" == "1" || "${CCO_CREATE_PRIVATE_S3_BUCKET:-}" == "true" ]]; then
  ccoctl_args+=(--create-private-s3-bucket)
fi

log "Using AWS profile for ccoctl: ${profile_label}"
log "Running ccoctl ${ccoctl_args[*]}"
"${aws_env[@]}" ccoctl "${ccoctl_args[@]}"

if [[ ! -d "${cco_output_dir}/manifests" ]]; then
  fail "ccoctl did not produce manifests at ${cco_output_dir}/manifests"
fi
mkdir -p "${installer_dir}/manifests"
cp -a "${cco_output_dir}/manifests/." "${installer_dir}/manifests/"

log "Manual STS prep complete. Run scripts/cluster-create.sh ${CLUSTER} next."

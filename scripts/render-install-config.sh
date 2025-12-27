#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Renders clusters/<cluster>/install-config.yaml.tmpl into clusters/<cluster>/.work/install-config.yaml.
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
template="${cluster_dir}/install-config.yaml.tmpl"
work_dir="${cluster_dir}/.work"
output="${work_dir}/install-config.yaml"
secrets_dir="${repo_root}/secrets/${CLUSTER}"
tf_outputs="${work_dir}/terraform-prereqs.json"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"
[[ -f "${template}" ]] || fail "Missing ${template}"
[[ -f "${secrets_dir}/pull-secret.json" ]] || fail "Missing ${secrets_dir}/pull-secret.json"
[[ -f "${secrets_dir}/ssh.pub" ]] || fail "Missing ${secrets_dir}/ssh.pub"

required_cmds=(yq jq sed)
for cmd in "${required_cmds[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
done

"${script_dir}/validate.sh" "${CLUSTER}"

cluster_name="$(yq -r '.name' "${cluster_yaml}")"
base_domain="$(yq -r '.dns.base_domain' "${cluster_yaml}")"
compute_replicas="$(yq -r '.openshift.compute_replicas' "${cluster_yaml}")"
control_plane_replicas="$(yq -r '.openshift.control_plane_replicas' "${cluster_yaml}")"
instance_type_compute="$(yq -r '.openshift.instance_type_compute' "${cluster_yaml}")"
instance_type_control_plane="$(yq -r '.openshift.instance_type_control_plane' "${cluster_yaml}")"
region="$(yq -r '.platform.region' "${cluster_yaml}")"
zones_json="$(yq -o=json '.platform.zones' "${cluster_yaml}" | tr -d '\n')"

pull_secret="$(tr -d '\n' < "${secrets_dir}/pull-secret.json")"
ssh_pub="$(tr -d '\n' < "${secrets_dir}/ssh.pub")"

hosted_zone_id=""
if [[ -f "${tf_outputs}" ]]; then
  hosted_zone_id="$(jq -r '.hosted_zone_id.value // empty' "${tf_outputs}")"
fi

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

sed_args=(
  -e "s|__CLUSTER_NAME__|$(escape_sed "${cluster_name}")|g"
  -e "s|__BASE_DOMAIN__|$(escape_sed "${base_domain}")|g"
  -e "s|__COMPUTE_REPLICAS__|$(escape_sed "${compute_replicas}")|g"
  -e "s|__CONTROL_PLANE_REPLICAS__|$(escape_sed "${control_plane_replicas}")|g"
  -e "s|__INSTANCE_TYPE_COMPUTE__|$(escape_sed "${instance_type_compute}")|g"
  -e "s|__INSTANCE_TYPE_CONTROL_PLANE__|$(escape_sed "${instance_type_control_plane}")|g"
  -e "s|__AWS_REGION__|$(escape_sed "${region}")|g"
  -e "s|__AWS_ZONES__|$(escape_sed "${zones_json}")|g"
  -e "s|__PULL_SECRET__|$(escape_sed "${pull_secret}")|g"
  -e "s|__SSH_PUB_KEY__|$(escape_sed "${ssh_pub}")|g"
  -e "s|__HOSTED_ZONE_ID__|$(escape_sed "${hosted_zone_id}")|g"
)

mkdir -p "${work_dir}"
umask 077
sed "${sed_args[@]}" "${template}" > "${output}"

log "Rendered install-config to ${output}"

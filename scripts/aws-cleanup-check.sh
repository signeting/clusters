#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Reports remaining AWS resources tagged as belonging to the cluster (by installer infraID).
Use after cluster destroy to confirm cleanup, including cross-AZ GPU workers/subnets.

You can also set CLUSTER=<cluster> instead of passing an argument.

Optional env:
  INFRA_ID            Override infraID (otherwise read from .work/installer/metadata.json)
  FAIL_ON_OWNED       If set to 0/false, do not exit non-zero when owned resources remain (default: true)
  INCLUDE_SHARED      If set to 0/false, do not report shared resources (default: true)
  OWNED_WAIT_SECONDS  If set >0, wait up to this many seconds for owned resources to reach 0 (default: 0)
  OWNED_WAIT_INTERVAL_SECONDS  Poll interval in seconds while waiting (default: 30)
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
installer_metadata="${cluster_dir}/.work/installer/metadata.json"
infra_id_file="${cluster_dir}/.work/infraID"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"

# Cleanup reporting must not be blocked on installer version checks.
PREFLIGHT_SKIP_SECRETS=1 \
PREFLIGHT_SKIP_OPENSHIFT_INSTALLER_VERSION_CHECK=1 \
  "${script_dir}/preflight.sh" "${CLUSTER}"

region="$(yq -r '.platform.region' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"
if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
  export AWS_PROFILE="${aws_profile}"
fi
export AWS_SDK_LOAD_CONFIG=1
export AWS_PAGER=""

infra_id="${INFRA_ID:-}"
if [[ -z "${infra_id}" ]]; then
  if [[ -f "${installer_metadata}" ]]; then
    infra_id="$(jq -r '.infraID // empty' "${installer_metadata}")"
  elif [[ -f "${infra_id_file}" ]]; then
    infra_id="$(tr -d '\n' < "${infra_id_file}")"
  else
    fail "Could not determine infraID (missing ${installer_metadata} and ${infra_id_file}; set INFRA_ID=...)"
  fi
fi
[[ -n "${infra_id}" ]] || fail "Could not determine infraID (set INFRA_ID=...)"

tag_key="kubernetes.io/cluster/${infra_id}"
owned_filter="Name=tag:${tag_key},Values=owned"
tag_filter="Name=tag:${tag_key},Values=owned,shared"

log "AWS cleanup check: cluster=${CLUSTER}, region=${region}, infraID=${infra_id}"

report_ec2_instances() {
  log "EC2 instances (owned/shared, non-terminated)"
  # shellcheck disable=SC2016
  aws ec2 describe-instances --region "${region}" \
    --filters "${tag_filter}" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].{InstanceId:InstanceId,AZ:Placement.AvailabilityZone,State:State.Name,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table || true
}

report_ec2_instances_terminated() {
  log "EC2 instances (owned/shared, terminated)"
  # shellcheck disable=SC2016
  aws ec2 describe-instances --region "${region}" \
    --filters "${tag_filter}" "Name=instance-state-name,Values=terminated" \
    --query 'Reservations[].Instances[].{InstanceId:InstanceId,AZ:Placement.AvailabilityZone,State:State.Name,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table || true
}

report_ec2_subnets() {
  log "EC2 subnets (owned/shared)"
  # shellcheck disable=SC2016
  aws ec2 describe-subnets --region "${region}" \
    --filters "${tag_filter}" \
    --query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
    --output table || true
}

report_ec2_nat_gateways() {
  log "NAT gateways (owned/shared)"
  aws ec2 describe-nat-gateways --region "${region}" \
    --filter "Name=tag:${tag_key},Values=owned,shared" \
    --query 'NatGateways[].{NatGatewayId:NatGatewayId,State:State,SubnetId:SubnetId,VpcId:VpcId}' \
    --output table || true
}

report_ec2_network_interfaces() {
  log "Network interfaces (owned/shared)"
  aws ec2 describe-network-interfaces --region "${region}" \
    --filters "${tag_filter}" \
    --query 'NetworkInterfaces[].{EniId:NetworkInterfaceId,Status:Status,Type:InterfaceType,SubnetId:SubnetId,InstanceId:Attachment.InstanceId,PrivateIp:PrivateIpAddress}' \
    --output table || true
}

report_ec2_volumes() {
  log "EBS volumes (owned/shared)"
  aws ec2 describe-volumes --region "${region}" \
    --filters "${tag_filter}" \
    --query 'Volumes[].{VolumeId:VolumeId,State:State,AZ:AvailabilityZone,SizeGiB:Size,Type:VolumeType,InstanceId:Attachments[0].InstanceId}' \
    --output table || true
}

get_tagged_arns() {
  local value="$1"
  aws resourcegroupstaggingapi get-resources --region "${region}" \
    --tag-filters "Key=${tag_key},Values=${value}" \
    --output json
}

count_json_list() {
  jq -r 'length'
}

count_live_owned_instances() {
  aws ec2 describe-instances --region "${region}" \
    --filters "${owned_filter}" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output json \
    | count_json_list
}

count_live_owned_vpcs() {
  aws ec2 describe-vpcs --region "${region}" \
    --filters "${owned_filter}" \
    --query 'Vpcs[].VpcId' --output json \
    | count_json_list
}

count_live_owned_subnets() {
  aws ec2 describe-subnets --region "${region}" \
    --filters "${owned_filter}" \
    --query 'Subnets[].SubnetId' --output json \
    | count_json_list
}

count_live_owned_enis() {
  aws ec2 describe-network-interfaces --region "${region}" \
    --filters "${owned_filter}" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output json \
    | count_json_list
}

count_live_owned_volumes() {
  aws ec2 describe-volumes --region "${region}" \
    --filters "${owned_filter}" \
    --query 'Volumes[].VolumeId' --output json \
    | count_json_list
}

count_live_owned_eips() {
  aws ec2 describe-addresses --region "${region}" \
    --filters "${owned_filter}" \
    --query 'Addresses[].AllocationId' --output json \
    | count_json_list
}

count_live_owned_nat_gateways() {
  aws ec2 describe-nat-gateways --region "${region}" \
    --filter "Name=tag:${tag_key},Values=owned" \
    --output json \
    | jq -r '[.NatGateways[]? | select(.State != "deleted")] | length'
}

get_live_owned_summary() {
  live_owned_instances="$(count_live_owned_instances)"
  live_owned_vpcs="$(count_live_owned_vpcs)"
  live_owned_subnets="$(count_live_owned_subnets)"
  live_owned_enis="$(count_live_owned_enis)"
  live_owned_volumes="$(count_live_owned_volumes)"
  live_owned_eips="$(count_live_owned_eips)"
  live_owned_nat_gateways="$(count_live_owned_nat_gateways)"

  live_owned_total="$((live_owned_instances + live_owned_vpcs + live_owned_subnets + live_owned_enis + live_owned_volumes + live_owned_eips + live_owned_nat_gateways))"
}

owned_json=""
owned_count="unknown"
if owned_json="$(get_tagged_arns owned)"; then
  owned_count="$(printf '%s' "${owned_json}" | jq -r '.ResourceTagMappingList | length')"
else
  log "WARN: failed to query Resource Groups Tagging API (owned). Continuing with EC2-only checks."
fi

include_shared="1"
if [[ "${INCLUDE_SHARED:-}" == "0" || "${INCLUDE_SHARED:-}" == "false" ]]; then
  include_shared="0"
fi

shared_count="0"
shared_json=""
if [[ "${include_shared}" == "1" ]]; then
  if shared_json="$(get_tagged_arns shared)"; then
    shared_count="$(printf '%s' "${shared_json}" | jq -r '.ResourceTagMappingList | length')"
  else
    log "WARN: failed to query Resource Groups Tagging API (shared)."
    shared_json=""
    shared_count="unknown"
  fi
fi

get_live_owned_summary
log "Tagged resources (eventually consistent): owned=${owned_count}, shared=${shared_count} (tag key: ${tag_key})"
log "Live owned resources: instances=${live_owned_instances}, vpcs=${live_owned_vpcs}, subnets=${live_owned_subnets}, enis=${live_owned_enis}, volumes=${live_owned_volumes}, eips=${live_owned_eips}, nat_gateways=${live_owned_nat_gateways} (sum=${live_owned_total})"

fail_on_owned="1"
if [[ "${FAIL_ON_OWNED:-}" == "0" || "${FAIL_ON_OWNED:-}" == "false" ]]; then
  fail_on_owned="0"
fi

owned_wait_seconds="${OWNED_WAIT_SECONDS:-0}"
owned_wait_interval="${OWNED_WAIT_INTERVAL_SECONDS:-30}"
if [[ "${fail_on_owned}" == "1" && "${live_owned_total}" != "0" && "${owned_wait_seconds}" != "0" ]]; then
  deadline="$(( $(date +%s) + owned_wait_seconds ))"
  while [[ "${live_owned_total}" != "0" && "$(date +%s)" -lt "${deadline}" ]]; do
    log "Live owned resources still present (sum=${live_owned_total}); waiting ${owned_wait_interval}s..."
    sleep "${owned_wait_interval}"

    get_live_owned_summary
  done
  log "Post-wait live owned resources: instances=${live_owned_instances}, vpcs=${live_owned_vpcs}, subnets=${live_owned_subnets}, enis=${live_owned_enis}, volumes=${live_owned_volumes}, eips=${live_owned_eips}, nat_gateways=${live_owned_nat_gateways} (sum=${live_owned_total})"
fi

report_ec2_instances
report_ec2_instances_terminated
report_ec2_subnets
report_ec2_nat_gateways
report_ec2_network_interfaces
report_ec2_volumes

if [[ "${fail_on_owned}" == "1" && "${live_owned_total}" != "0" ]]; then
  if [[ "${owned_count}" != "unknown" && "${owned_count}" != "0" ]]; then
    log "Owned resource ARNs (debugging; tagging API is eventually consistent):"
    printf '%s' "${owned_json}" | jq -r '.ResourceTagMappingList[].ResourceARN' | sed 's/^/  - /'
  fi
  fail "Live owned resources still present for infraID=${infra_id} (sum=${live_owned_total}). Re-run after a few minutes; if they persist, delete them manually."
fi

log "Cleanup check complete."

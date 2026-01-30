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

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"

PREFLIGHT_SKIP_SECRETS=1 "${script_dir}/preflight.sh" "${CLUSTER}"

region="$(yq -r '.platform.region' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"
if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
  export AWS_PROFILE="${aws_profile}"
fi
export AWS_SDK_LOAD_CONFIG=1
export AWS_PAGER=""

infra_id="${INFRA_ID:-}"
if [[ -z "${infra_id}" ]]; then
  [[ -f "${installer_metadata}" ]] || fail "Missing ${installer_metadata} (or set INFRA_ID=...)"
  infra_id="$(jq -r '.infraID // empty' "${installer_metadata}")"
fi
[[ -n "${infra_id}" ]] || fail "Could not determine infraID (set INFRA_ID=...)"

tag_key="kubernetes.io/cluster/${infra_id}"
tag_filter="Name=tag:${tag_key},Values=owned,shared"

log "AWS cleanup check: cluster=${CLUSTER}, region=${region}, infraID=${infra_id}"

report_ec2_instances() {
  log "EC2 instances (owned/shared, non-terminated)"
  # shellcheck disable=SC2016
  aws ec2 describe-instances --region "${region}" \
    --filters "${tag_filter}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
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

log "Tagged resources: owned=${owned_count}, shared=${shared_count} (tag key: ${tag_key})"

fail_on_owned="1"
if [[ "${FAIL_ON_OWNED:-}" == "0" || "${FAIL_ON_OWNED:-}" == "false" ]]; then
  fail_on_owned="0"
fi

owned_wait_seconds="${OWNED_WAIT_SECONDS:-0}"
owned_wait_interval="${OWNED_WAIT_INTERVAL_SECONDS:-30}"
if [[ "${fail_on_owned}" == "1" && "${owned_count}" != "0" && "${owned_count}" != "unknown" && "${owned_wait_seconds}" != "0" ]]; then
  deadline="$(( $(date +%s) + owned_wait_seconds ))"
  while [[ "${owned_count}" != "0" && "$(date +%s)" -lt "${deadline}" ]]; do
    log "Owned resources still present (count=${owned_count}); waiting ${owned_wait_interval}s..."
    sleep "${owned_wait_interval}"

    if owned_json="$(get_tagged_arns owned)"; then
      owned_count="$(printf '%s' "${owned_json}" | jq -r '.ResourceTagMappingList | length')"
    else
      log "WARN: failed to query Resource Groups Tagging API during wait; stopping wait early."
      owned_count="unknown"
      break
    fi
  done
  log "Post-wait tagged resources: owned=${owned_count}, shared=${shared_count} (tag key: ${tag_key})"
fi

report_ec2_instances
report_ec2_subnets
report_ec2_nat_gateways
report_ec2_network_interfaces
report_ec2_volumes

if [[ "${owned_count}" != "0" && "${owned_count}" != "unknown" ]]; then
  log "Owned resource ARNs (expected to be empty after successful destroy):"
  printf '%s' "${owned_json}" | jq -r '.ResourceTagMappingList[].ResourceARN' | sed 's/^/  - /'
fi

if [[ "${include_shared}" == "1" && "${shared_count}" != "0" && "${shared_count}" != "unknown" ]]; then
  log "Shared resource ARNs (often manually-managed subnets/etc; review and delete if no longer needed):"
  printf '%s' "${shared_json}" | jq -r '.ResourceTagMappingList[].ResourceARN' | sed 's/^/  - /'
fi

if [[ "${fail_on_owned}" == "1" && "${owned_count}" != "0" && "${owned_count}" != "unknown" ]]; then
  fail "Owned resources still present for infraID=${infra_id}. Re-run after a few minutes; if they persist, delete them manually."
fi

log "Cleanup check complete."

#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Converts worker MachineSets to use Spot and scales them to openshift.compute_replicas.

This is currently AWS-only. It patches worker MachineSets so that new Machines are
created as Spot instances. Existing worker Machines are not automatically replaced.

You can also set CLUSTER=<cluster> instead of passing an argument.

Optional env:
  WAIT_TIMEOUT_SECONDS   Default: 3600
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
kubeconfig="${work_dir}/kubeconfig"

[[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"
[[ -f "${kubeconfig}" ]] || fail "Missing kubeconfig at ${kubeconfig} (run make cluster-create first)"

required_cmds=(oc jq yq)
for cmd in "${required_cmds[@]}"; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
done

platform_type="$(yq -r '.platform.type' "${cluster_yaml}")"
[[ "${platform_type}" == "aws" ]] || fail "spot-workers only supports platform.type=aws (found: ${platform_type})"

desired_replicas="$(yq -r '.openshift.compute_replicas' "${cluster_yaml}")"
compute_market="$(yq -r '.openshift.compute_market // "on-demand"' "${cluster_yaml}")"
aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"
region="$(yq -r '.platform.region' "${cluster_yaml}")"

if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
  export AWS_PROFILE="${aws_profile}"
fi
export AWS_SDK_LOAD_CONFIG=1
log "Using AWS_PROFILE=${AWS_PROFILE:-default} (region: ${region})"

if [[ "${compute_market}" != "spot" ]]; then
  log "WARN: openshift.compute_market is ${compute_market}; proceeding anyway"
fi

if [[ "${desired_replicas}" == "0" ]]; then
  log "openshift.compute_replicas=0; nothing to do"
  exit 0
fi

export KUBECONFIG="${kubeconfig}"
oc whoami >/dev/null 2>&1 || fail "oc not authenticated (check kubeconfig)"

machinesets_json="$(oc -n openshift-machine-api get machinesets -o json)"
mapfile -t worker_machinesets < <(
  printf '%s' "${machinesets_json}" \
    | jq -r '.items[]
      | select(
          (.metadata.labels["machine.openshift.io/cluster-api-machine-role"]=="worker")
          or
          (.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"]=="worker")
        )
      | .metadata.name' \
    | sort
)

if (( ${#worker_machinesets[@]} == 0 )); then
  fail "No worker MachineSets found in openshift-machine-api"
fi

patch_json='{"spec":{"template":{"spec":{"providerSpec":{"value":{"spotMarketOptions":{}}}}}}}'
for ms in "${worker_machinesets[@]}"; do
  log "Patching MachineSet to Spot: ${ms}"
  oc -n openshift-machine-api patch machineset "${ms}" --type=merge -p "${patch_json}" >/dev/null
done

ms_count="${#worker_machinesets[@]}"
base=$((desired_replicas / ms_count))
rem=$((desired_replicas % ms_count))
for i in "${!worker_machinesets[@]}"; do
  replicas="${base}"
  if (( i < rem )); then
    replicas=$((replicas + 1))
  fi
  log "Scaling MachineSet ${worker_machinesets[$i]} to ${replicas}"
  oc -n openshift-machine-api scale machineset "${worker_machinesets[$i]}" --replicas="${replicas}" >/dev/null
done

timeout_seconds="${WAIT_TIMEOUT_SECONDS:-3600}"
deadline="$(( $(date +%s) + timeout_seconds ))"
while true; do
  now="$(date +%s)"
  if (( now > deadline )); then
    fail "Timed out waiting for ${desired_replicas} worker nodes to be Ready"
  fi

  # NOTE: In "compact" clusters, control-plane nodes may also have the worker role label.
  # We want to wait for dedicated workers only (i.e., worker label present, master/control-plane absent).
  nodes_json="$(oc get nodes -o json)"
  total_workers="$(printf '%s' "${nodes_json}" | jq '[.items[]
    | select(.metadata.labels["node-role.kubernetes.io/worker"] != null)
    | select(.metadata.labels["node-role.kubernetes.io/master"] == null)
    | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null)
  ] | length')"
  ready_workers="$(printf '%s' "${nodes_json}" | jq '[.items[]
    | select(.metadata.labels["node-role.kubernetes.io/worker"] != null)
    | select(.metadata.labels["node-role.kubernetes.io/master"] == null)
    | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null)
    | select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))
  ] | length')"

  machinesets_json="$(oc -n openshift-machine-api get machinesets -o json)"
  ms_desired="$(printf '%s' "${machinesets_json}" | jq '[.items[]
    | select(
        (.metadata.labels["machine.openshift.io/cluster-api-machine-role"]=="worker")
        or
        (.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"]=="worker")
      )
    | (.spec.replicas // 0)
  ] | add // 0')"
  ms_ready="$(printf '%s' "${machinesets_json}" | jq '[.items[]
    | select(
        (.metadata.labels["machine.openshift.io/cluster-api-machine-role"]=="worker")
        or
        (.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"]=="worker")
      )
    | (.status.readyReplicas // 0)
  ] | add // 0')"

  log "Dedicated worker nodes Ready: ${ready_workers}/${desired_replicas} (seen: ${total_workers}); MachineSets ready: ${ms_ready}/${ms_desired}"
  if (( ready_workers >= desired_replicas )); then
    break
  fi
  sleep 10
done

log "Spot workers ready. Next: make verify CLUSTER=${CLUSTER}"

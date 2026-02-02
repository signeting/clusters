#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 <cluster>

Monitors an in-progress cluster create (make cluster-create) by watching the
cluster-create log, installer log, and (when available) oc connectivity.

Writes a one-line status summary to clusters/<cluster>/.work/create-status.txt
and a final summary to clusters/<cluster>/.work/create-final.txt.

Exits 0 on success, non-zero on failure/timeout.

Optional env:
  TIMEOUT_SECONDS   Max seconds to wait (default: 14400 = 4h)
  INTERVAL_SECONDS  Poll interval (default: 30)
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
work_dir="${cluster_dir}/.work"
logs_dir="${work_dir}/logs"

mkdir -p "${work_dir}"

timeout_seconds="${TIMEOUT_SECONDS:-14400}"
interval_seconds="${INTERVAL_SECONDS:-30}"

status_file="${work_dir}/create-status.txt"
final_file="${work_dir}/create-final.txt"

latest_log() {
  # shellcheck disable=SC2012
  ls -1t "${logs_dir}"/cluster-create-*.log 2>/dev/null | head -n 1 || true
}

tail_snip() {
  local f="$1"
  [[ -f "${f}" ]] || return 0
  tail -n 60 "${f}" | sed 's/[[:cntrl:]]//g' || true
}

write_status() {
  local msg="$1"
  printf '%s\n' "${msg}" > "${status_file}"
}

summarize_failure() {
  local log_file="$1"
  local installer_log="${work_dir}/installer/.openshift_install.log"
  {
    log "Create FAILED for cluster=${CLUSTER}"
    log "cluster-create log: ${log_file:-<none>}"
    log "installer log: ${installer_log}"
    echo
    echo "---- cluster-create tail ----"
    tail_snip "${log_file}"
    echo
    echo "---- installer tail ----"
    tail_snip "${installer_log}"
  } > "${final_file}"
  cat "${final_file}"
}

summarize_success() {
  local log_file="$1"
  local installer_log="${work_dir}/installer/.openshift_install.log"
  local kubeconfig="${work_dir}/kubeconfig"
  {
    log "Create SUCCEEDED for cluster=${CLUSTER}"
    log "cluster-create log: ${log_file:-<none>}"
    log "installer log: ${installer_log}"
    if [[ -f "${work_dir}/installer/metadata.json" ]]; then
      log "infraID: $(jq -r .infraID "${work_dir}/installer/metadata.json" 2>/dev/null || true)"
    fi
    echo
    if [[ -f "${kubeconfig}" ]]; then
      log "oc checks (best-effort)"
      KUBECONFIG="${kubeconfig}" oc get clusterversion 2>/dev/null || true
      KUBECONFIG="${kubeconfig}" oc get nodes 2>/dev/null || true
      KUBECONFIG="${kubeconfig}" oc get co 2>/dev/null || true
    else
      log "kubeconfig not found at ${kubeconfig} (unexpected after success)"
    fi
    echo
    echo "---- cluster-create tail ----"
    tail_snip "${log_file}"
    echo
    echo "---- installer tail ----"
    tail_snip "${installer_log}"
  } > "${final_file}"
  cat "${final_file}"
}

start_ts="$(date +%s)"
log_file="$(latest_log)"

if [[ -z "${log_file}" ]]; then
  fail "No cluster-create logs found under ${logs_dir}"
fi

log "Monitoring cluster create: cluster=${CLUSTER}, log=${log_file}"
write_status "monitoring: starting (log=${log_file})"

while :; do
  now="$(date +%s)"
  elapsed="$((now - start_ts))"
  if (( elapsed > timeout_seconds )); then
    write_status "timeout: ${elapsed}s exceeded"
    summarize_failure "${log_file}"
    exit 1
  fi

  # Refresh log path in case of new attempt.
  new_log="$(latest_log)"
  if [[ -n "${new_log}" && "${new_log}" != "${log_file}" ]]; then
    log_file="${new_log}"
    log "Switching to newest log: ${log_file}"
  fi

  # Success/failure heuristics based on logs.
  if rg -q "Cluster create complete\\. Kubeconfig:" "${log_file}"; then
    write_status "success: cluster-create complete"
    summarize_success "${log_file}"
    exit 0
  fi

  if rg -q "FATAL:" "${log_file}"; then
    write_status "failure: FATAL in cluster-create log"
    summarize_failure "${log_file}"
    exit 2
  fi

  installer_log="${work_dir}/installer/.openshift_install.log"
  if [[ -f "${installer_log}" ]] && rg -q "level=error" "${installer_log}"; then
    write_status "failure: error in installer log"
    summarize_failure "${log_file}"
    exit 3
  fi

  # If the create process died unexpectedly, report failure and include tails.
  if [[ -f "${work_dir}/cluster-create.pid" ]]; then
    pid="$(cat "${work_dir}/cluster-create.pid" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
      write_status "failure: cluster-create process exited (pid=${pid})"
      # Determine whether it actually succeeded (race) by checking kubeconfig existence.
      if [[ -f "${work_dir}/kubeconfig" ]]; then
        summarize_success "${log_file}"
        exit 0
      fi
      summarize_failure "${log_file}"
      exit 4
    fi
  fi

  # Emit a concise periodic status line.
  infra="(infraID: n/a)"
  if [[ -f "${work_dir}/installer/metadata.json" ]]; then
    infra="(infraID: $(jq -r .infraID "${work_dir}/installer/metadata.json" 2>/dev/null || echo n/a))"
  fi
  write_status "running: ${elapsed}s ${infra} log=$(basename "${log_file}")"

  sleep "${interval_seconds}"
done

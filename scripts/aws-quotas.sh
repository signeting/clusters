#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "FATAL: $*"; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  aws-quotas.sh <cluster>
  aws-quotas.sh --all
  CLUSTER=<cluster> aws-quotas.sh

Reports (and optionally enforces) AWS EC2 vCPU quotas vs. current usage for the
instance types referenced by clusters/<cluster>/cluster.yaml.

By default, the script checks whether there is enough headroom to reach the
desired replicas in cluster.yaml. If the cluster already exists (installer
metadata present and tagged instances found), it only checks the delta between
current cluster-owned capacity and desired capacity.

Optional env:
  FAIL_ON_INSUFFICIENT   Default: 1 (set to 0/false to only warn)
  SKIP_ACCOUNT_CHECK     Default: 0 (set to 1/true to skip STS account guardrail)

  Notes:
  - Quotas are regional and vCPU-based (Service Quotas: EC2).
  - For new installs, the OpenShift installer temporarily uses a bootstrap node;
    this script includes that peak automatically until cluster-owned instances
    are detected for the infraID.
USAGE
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

as_int() {
  awk -v n="${1:-0}" 'BEGIN { printf "%.0f\n", n }'
}

quota_category_for_instance_type() {
  local instance_type="$1"
  local family="${instance_type%%.*}"

  if [[ "${family}" == g* || "${family}" == vt* ]]; then
    printf 'g_vt'
    return 0
  fi
  if [[ "${family}" == p* ]]; then
    printf 'p'
    return 0
  fi
  if [[ "${family}" == f* ]]; then
    printf 'f'
    return 0
  fi
  if [[ "${family}" == inf* ]]; then
    printf 'inf'
    return 0
  fi
  if [[ "${family}" == trn* ]]; then
    printf 'trn'
    return 0
  fi
  if [[ "${family}" == dl* ]]; then
    printf 'dl'
    return 0
  fi
  printf 'standard'
}

quota_label_for_category() {
  case "$1" in
    standard) printf 'Standard (A/C/D/H/I/M/R/T/Z)' ;;
    g_vt) printf 'G and VT' ;;
    p) printf 'P' ;;
    f) printf 'F' ;;
    inf) printf 'Inf' ;;
    trn) printf 'Trn' ;;
    dl) printf 'DL' ;;
    *) printf '%s' "$1" ;;
  esac
}

quota_regex_for() {
  local usage_key="$1" # on_demand | spot
  local category="$2"

  if [[ "${usage_key}" == "on_demand" ]]; then
    case "${category}" in
      standard) printf '^Running On-Demand Standard' ;;
      g_vt) printf '^Running On-Demand G and VT' ;;
      p) printf '^Running On-Demand P' ;;
      f) printf '^Running On-Demand F' ;;
      inf) printf '^Running On-Demand Inf' ;;
      trn) printf '^Running On-Demand Trn' ;;
      dl) printf '^Running On-Demand DL' ;;
      *) return 1 ;;
    esac
    return 0
  fi

  if [[ "${usage_key}" == "spot" ]]; then
    case "${category}" in
      standard) printf 'Standard.*Spot Instance Requests' ;;
      g_vt) printf 'G and VT.*Spot Instance Requests' ;;
      p) printf '^All P .*Spot Instance Requests' ;;
      f) printf '^All F .*Spot Instance Requests' ;;
      inf) printf 'Inf.*Spot Instance Requests' ;;
      trn) printf 'Trn.*Spot Instance Requests' ;;
      dl) printf 'DL.*Spot Instance Requests' ;;
      *) return 1 ;;
    esac
    return 0
  fi

  return 1
}

fetch_instance_type_vcpu_map() {
  local region="$1"
  shift
  local -a instance_types=("$@")

  if (( ${#instance_types[@]} == 0 )); then
    return 0
  fi

  local -a uniq_types=()
  local t
  for t in "${instance_types[@]}"; do
    [[ -n "${t}" ]] || continue
    if [[ " ${uniq_types[*]} " == *" ${t} "* ]]; then
      continue
    fi
    uniq_types+=("${t}")
  done

  local chunk_size=100
  local i=0
  while (( i < ${#uniq_types[@]} )); do
    local -a chunk=("${uniq_types[@]:i:chunk_size}")
    i=$((i + chunk_size))
    aws "${aws_args[@]}" ec2 describe-instance-types \
      --region "${region}" \
      --instance-types "${chunk[@]}" \
      --output json \
      | jq -r '.InstanceTypes[] | "\(.InstanceType)\t\(.VCpuInfo.DefaultVCpus)"'
  done
}

describe_instances_types_and_lifecycle() {
  local region="$1"
  shift
  aws "${aws_args[@]}" ec2 describe-instances \
    --region "${region}" \
    --filters "$@" \
    --query 'Reservations[].Instances[].{InstanceType:InstanceType, Lifecycle:InstanceLifecycle}' \
    --output json
}

instance_counts_tsv() {
  jq -r '
    map({t: .InstanceType, l: (.Lifecycle // "on-demand")})
    | sort_by(.t, .l)
    | group_by([.t, .l])
    | .[]
    | "\(.[0].t)\t\(.[0].l)\t\(length)"'
}

init_totals() {
  local prefix="$1"
  local usage_key category
  for usage_key in on_demand spot; do
    for category in standard g_vt p f inf trn dl; do
      eval "${prefix}_${usage_key}_${category}=0"
    done
  done
}

add_to_total() {
  local prefix="$1"
  local usage_key="$2"
  local category="$3"
  local amount="$4"

  local var="${prefix}_${usage_key}_${category}"
  local current
  current="$(eval "printf '%s' \"\${${var}}\"")"
  eval "${var}=$((current + amount))"
}

get_total() {
  local prefix="$1"
  local usage_key="$2"
  local category="$3"
  local var="${prefix}_${usage_key}_${category}"
  eval "printf '%s' \"\${${var}}\""
}

accumulate_usage_totals_from_instances_json() {
  local region="$1"
  local instances_json="$2"
  local totals_prefix="$3"

  local counts
  counts="$(printf '%s' "${instances_json}" | instance_counts_tsv || true)"

  if [[ -z "${counts}" ]]; then
    return 0
  fi

  local -a types=()
  while IFS=$'\t' read -r instance_type _rest; do
    [[ -n "${instance_type}" ]] || continue
    types+=("${instance_type}")
  done <<< "${counts}"

  local vcpu_map_file
  vcpu_map_file="$(mktemp)"
  fetch_instance_type_vcpu_map "${region}" "${types[@]}" > "${vcpu_map_file}"

  while IFS=$'\t' read -r instance_type lifecycle count; do
    [[ -n "${instance_type}" ]] || continue
    [[ -n "${count}" ]] || continue

    local vcpus
    vcpus="$(awk -v t="${instance_type}" '$1==t {print $2}' "${vcpu_map_file}" | head -n1)"
    [[ -n "${vcpus}" ]] || fail "Could not determine vCPUs for instance type ${instance_type} (region: ${region})"

    local usage_key="on_demand"
    if [[ "${lifecycle}" == "spot" ]]; then
      usage_key="spot"
    fi

    local category
    category="$(quota_category_for_instance_type "${instance_type}")"

    add_to_total "${totals_prefix}" "${usage_key}" "${category}" "$((vcpus * count))"
  done <<< "${counts}"

  rm -f "${vcpu_map_file}"
}

report_and_check_cluster() {
  local cluster="$1"

  local script_dir repo_root cluster_dir cluster_yaml
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  cluster_dir="${repo_root}/clusters/${cluster}"
  cluster_yaml="${cluster_dir}/cluster.yaml"

  [[ -f "${cluster_yaml}" ]] || fail "Missing ${cluster_yaml}"
  "${script_dir}/validate.sh" "${cluster}" >/dev/null

  local platform_type region account_id aws_profile
  platform_type="$(yq -r '.platform.type' "${cluster_yaml}")"
  [[ "${platform_type}" == "aws" ]] || fail "Only platform.type=aws is supported (cluster: ${cluster})"

  region="$(yq -r '.platform.region' "${cluster_yaml}")"
  account_id="$(yq -r '.platform.account_id' "${cluster_yaml}")"
  aws_profile="$(yq -r '.credentials.aws_profile // ""' "${cluster_yaml}")"

  aws_args=()
  local profile_label="default"
  if [[ -n "${aws_profile}" && "${aws_profile}" != "null" ]]; then
    aws_args+=(--profile "${aws_profile}")
    profile_label="${aws_profile}"
  elif [[ -n "${AWS_PROFILE:-}" ]]; then
    profile_label="${AWS_PROFILE}"
  fi

  export AWS_SDK_LOAD_CONFIG=1

  if ! is_truthy "${SKIP_ACCOUNT_CHECK:-}"; then
    local identity_json caller_account caller_arn
    identity_json="$(aws "${aws_args[@]}" sts get-caller-identity --output json 2>/dev/null)" || {
      fail "Failed to call aws sts get-caller-identity (profile: ${profile_label})"
    }
    caller_account="$(printf '%s' "${identity_json}" | jq -r '.Account // empty')"
    caller_arn="$(printf '%s' "${identity_json}" | jq -r '.Arn // empty')"
    [[ -n "${caller_account}" ]] || fail "Could not read AWS account ID from STS response"
    if [[ "${caller_account}" != "${account_id}" ]]; then
      fail "AWS account mismatch: expected ${account_id}, got ${caller_account} (profile: ${profile_label})"
    fi
    log "AWS: profile=${profile_label}, caller=${caller_arn}, region=${region}"
  else
    log "WARN: skipping AWS account guardrail (SKIP_ACCOUNT_CHECK=1)"
  fi

  local cp_type compute_type cp_replicas compute_replicas compute_market
  cp_type="$(yq -r '.openshift.instance_type_control_plane' "${cluster_yaml}")"
  compute_type="$(yq -r '.openshift.instance_type_compute' "${cluster_yaml}")"
  cp_replicas="$(yq -r '.openshift.control_plane_replicas' "${cluster_yaml}")"
  compute_replicas="$(yq -r '.openshift.compute_replicas' "${cluster_yaml}")"
  compute_market="$(yq -r '.openshift.compute_market // "on-demand"' "${cluster_yaml}")"

  local compute_usage_key="on_demand"
  if [[ "${compute_market}" == "spot" ]]; then
    compute_usage_key="spot"
  fi

  local vcpu_map_file
  vcpu_map_file="$(mktemp)"
  fetch_instance_type_vcpu_map "${region}" "${cp_type}" "${compute_type}" > "${vcpu_map_file}"
  local cp_vcpus compute_vcpus
  cp_vcpus="$(awk -v t="${cp_type}" '$1==t {print $2}' "${vcpu_map_file}" | head -n1)"
  compute_vcpus="$(awk -v t="${compute_type}" '$1==t {print $2}' "${vcpu_map_file}" | head -n1)"
  rm -f "${vcpu_map_file}"
  [[ -n "${cp_vcpus}" ]] || fail "Could not determine vCPUs for control-plane instance type ${cp_type} (region: ${region})"
  [[ -n "${compute_vcpus}" ]] || fail "Could not determine vCPUs for compute instance type ${compute_type} (region: ${region})"

  local cp_category compute_category
  cp_category="$(quota_category_for_instance_type "${cp_type}")"
  compute_category="$(quota_category_for_instance_type "${compute_type}")"

  init_totals desired
  init_totals existing
  init_totals delta
  init_totals used
  init_totals quota

  add_to_total desired on_demand "${cp_category}" "$((cp_vcpus * cp_replicas))"
  if (( compute_replicas > 0 )); then
    add_to_total desired "${compute_usage_key}" "${compute_category}" "$((compute_vcpus * compute_replicas))"
  fi

  local metadata_json infra_id cluster_tag_filter_present="0"
  metadata_json="${cluster_dir}/.work/installer/metadata.json"
  if [[ -f "${metadata_json}" ]]; then
    infra_id="$(jq -r '.infraID // empty' "${metadata_json}" 2>/dev/null || true)"
    if [[ -n "${infra_id}" ]]; then
      local cluster_instances_json
      cluster_instances_json="$(describe_instances_types_and_lifecycle "${region}" \
        "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
        "Name=instance-state-name,Values=pending,running")"

      local cluster_instance_count
      cluster_instance_count="$(printf '%s' "${cluster_instances_json}" | jq -r 'length' 2>/dev/null || printf '0')"
      if [[ "${cluster_instance_count}" != "0" ]]; then
        cluster_tag_filter_present="1"
        accumulate_usage_totals_from_instances_json "${region}" "${cluster_instances_json}" existing
      fi
    fi
  fi

  local account_instances_json
  account_instances_json="$(describe_instances_types_and_lifecycle "${region}" \
    "Name=instance-state-name,Values=pending,running")"
  accumulate_usage_totals_from_instances_json "${region}" "${account_instances_json}" used

  local quotas_json
  quotas_json="$(aws "${aws_args[@]}" service-quotas list-service-quotas --service-code ec2 --region "${region}" --output json)"

  local -a relevant_categories=()
  local c
  for c in "${cp_category}" "${compute_category}"; do
    if [[ " ${relevant_categories[*]} " == *" ${c} "* ]]; then
      continue
    fi
    relevant_categories+=("${c}")
  done

  local usage_key category
  for usage_key in on_demand spot; do
    for category in "${relevant_categories[@]}"; do
      local re quota_value_raw quota_value_int
      re="$(quota_regex_for "${usage_key}" "${category}")" || continue
      quota_value_raw="$(printf '%s' "${quotas_json}" | jq -r --arg re "${re}" '
        [.Quotas[] | select(.QuotaName | test($re))]
        | if length == 0 then "" else .[0].Value end
      ')"
      if [[ -z "${quota_value_raw}" || "${quota_value_raw}" == "null" ]]; then
        continue
      fi
      quota_value_int="$(as_int "${quota_value_raw}")"
      add_to_total quota "${usage_key}" "${category}" "${quota_value_int}"
    done
  done

  for usage_key in on_demand spot; do
    for category in "${relevant_categories[@]}"; do
      local want have
      want="$(get_total desired "${usage_key}" "${category}")"
      have="$(get_total existing "${usage_key}" "${category}")"
      if (( have >= want )); then
        add_to_total delta "${usage_key}" "${category}" 0
      else
        add_to_total delta "${usage_key}" "${category}" "$((want - have))"
      fi
    done
  done

  local bootstrap_extra_vcpu=0
  if [[ "${cluster_tag_filter_present}" == "0" ]]; then
    bootstrap_extra_vcpu="${cp_vcpus}"
  fi

  log "EC2 vCPU quota check: cluster=${cluster}"
  log "Plan: control-plane ${cp_type} x${cp_replicas} (${cp_vcpus} vCPU each, on-demand, $(quota_label_for_category "${cp_category}"))"
  log "Plan: compute ${compute_type} x${compute_replicas} (${compute_vcpus} vCPU each, ${compute_market}, $(quota_label_for_category "${compute_category}"))"
  if [[ "${bootstrap_extra_vcpu}" != "0" ]]; then
    log "Plan: install peak includes +1 bootstrap (${cp_type}, +${bootstrap_extra_vcpu} on-demand vCPU)"
  elif [[ -f "${metadata_json}" ]]; then
    log "Plan: bootstrap not included (cluster-owned instances detected for infraID)"
  fi

  local enforce_fail="1"
  if ! is_truthy "${FAIL_ON_INSUFFICIENT:-1}"; then
    enforce_fail="0"
  fi

  local failed="0"
  local displayed_any="0"
  for usage_key in on_demand spot; do
    for category in "${relevant_categories[@]}"; do
      local quota_v used_v delta_v
      quota_v="$(get_total quota "${usage_key}" "${category}")"
      used_v="$(get_total used "${usage_key}" "${category}")"
      delta_v="$(get_total delta "${usage_key}" "${category}")"

      local pair_required="0"
      if [[ "${usage_key}" == "on_demand" && "${category}" == "${cp_category}" ]]; then
        pair_required="1"
      fi
      if (( compute_replicas > 0 )) && [[ "${usage_key}" == "${compute_usage_key}" && "${category}" == "${compute_category}" ]]; then
        pair_required="1"
      fi

      if (( quota_v == 0 )); then
        if [[ "${pair_required}" == "1" ]]; then
          local usage_label_missing="On-Demand"
          if [[ "${usage_key}" == "spot" ]]; then
            usage_label_missing="Spot"
          fi
          log "WARN: Missing Service Quotas entry for ${usage_label_missing} $(quota_label_for_category "${category}") vCPU limit (region: ${region})"
          failed="1"
        fi
        continue
      fi

      displayed_any="1"
      local extra=0
      if [[ "${usage_key}" == "on_demand" && "${category}" == "${cp_category}" ]]; then
        extra="${bootstrap_extra_vcpu}"
      fi

      local remaining
      remaining=$((quota_v - used_v - delta_v - extra))

      local usage_label="On-Demand"
      if [[ "${usage_key}" == "spot" ]]; then
        usage_label="Spot"
      fi

      local cat_label
      cat_label="$(quota_label_for_category "${category}")"
      local line="Quota ${usage_label} ${cat_label}: limit=${quota_v} vCPU, used=${used_v} vCPU, need=${delta_v} vCPU"
      if (( extra > 0 )); then
        line+=", install-peak-extra=${extra} vCPU"
      fi
      line+=", remaining=${remaining} vCPU"

      if (( remaining < 0 )); then
        log "WARN: ${line} (INSUFFICIENT)"
        failed="1"
      else
        log "OK: ${line}"
      fi
    done
  done

  if [[ "${displayed_any}" == "0" ]]; then
    log "WARN: Could not find matching EC2 vCPU quotas via Service Quotas (region: ${region})"
    if [[ "${enforce_fail}" == "1" ]]; then
      failed="1"
    fi
  fi

  if [[ "${failed}" == "1" && "${enforce_fail}" == "1" ]]; then
    return 1
  fi
  return 0
}

main() {
  local required_cmds=(aws jq yq awk)
  local cmd
  for cmd in "${required_cmds[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required tool: ${cmd}"
  done

  local mode="${1:-${CLUSTER:-}}"
  if [[ -z "${mode}" ]]; then
    usage
    exit 2
  fi

  local -a clusters=()
  if [[ "${mode}" == "--all" ]]; then
    local script_dir repo_root clusters_root
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "${script_dir}/.." && pwd)"
    clusters_root="${repo_root}/clusters"
    local d
    for d in "${clusters_root}"/*; do
      [[ -d "${d}" ]] || continue
      local base
      base="$(basename "${d}")"
      if [[ "${base}" == _* ]]; then
        continue
      fi
      if [[ -f "${d}/cluster.yaml" ]]; then
        clusters+=("${base}")
      fi
    done
    if (( ${#clusters[@]} == 0 )); then
      fail "No non-example clusters found under clusters/"
    fi
  else
    clusters+=("${mode}")
  fi

  local failures=0
  local c
  for c in "${clusters[@]}"; do
    if ! report_and_check_cluster "${c}"; then
      failures=$((failures + 1))
    fi
  done

  if (( failures > 0 )); then
    exit 1
  fi
}

aws_args=()
main "$@"

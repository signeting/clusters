# Session Handoff: GPU + Inferentia Node Pools (OpenShift on AWS)

Audience: an AI coding agent working in `bitiq-io/gitops` to add/operate specialized node pools (MachineSets) and the operators/config needed to use NVIDIA GPUs and (optionally) AWS Inferentia.

Date: 2026-01-14

---

## TL;DR

- We want to add **specialized worker pools** (GPU, maybe Inferentia) to our OpenShift cluster(s) on AWS.
- **Decision:** baseline cluster creation stays in `signeting/clusters` (Day‑0 + Day‑1), but **ongoing node pool management** (additional MachineSets, labels/taints, autoscaling) and **operators** (GPU Operator, Neuron components) should live in `bitiq-io/gitops` (Day‑2) so Argo CD can reconcile drift.
- **Guardrails remain outside the cluster:** AWS account checks + EC2 quota/usage sanity checks are enforced in `signeting/clusters` before creating/scaling capacity.

---

## Clarifying Questions (answer before/while implementing)

1. **Which cluster(s)** are in scope right now (only `prod`, or multiple)?
2. **Market choice per pool:** GPU and Inferentia pools should be Spot, On‑Demand, or mixed?
3. **Instance types to target:**
   - NVIDIA: `g5.*`, `g4dn.*`, `p4d/p5.*`, other?
   - Inferentia: `inf2.*` (preferred) vs `inf1.*`; Trainium (`trn1.*`) also in scope?
4. **Sizing + scaling approach:** fixed replicas or autoscaling?
   - If autoscaling: desired min/max for each pool; do we already run Cluster Autoscaler?
5. **Scheduling policy:** do we want these nodes **tainted** so only explicit workloads land on them?
6. **AZs:** stay single-AZ (`us-west-2a`) or add more zones for Spot diversity?
7. **Workloads:** what’s the first “hello world” workload to validate GPUs/Inferentia (namespaces, images, tolerations)?
8. **Operator constraints:** any restrictions on registries (disconnected/mirrors), or OperatorHub sources?

If any of these are unknown, implement the GPU pool first with conservative defaults (small, tainted, autoscaled 0→N) and keep Inferentia behind a feasibility gate.

---

## Current State: `signeting/clusters` (this repo)

### Cluster intent

- Single real cluster definition currently present:
  - `clusters/prod/cluster.yaml`
  - AWS account guardrail: `platform.account_id: "153526447089"`
  - Region/AZ: `us-west-2` / `["us-west-2a"]`
  - Control plane: `m6i.xlarge` x3 (On‑Demand)
  - Baseline compute: `r5a.2xlarge`, desired workers: `3`, `compute_market: spot`

### Important scripts/targets

- `make preflight CLUSTER=<cluster>`: validates tools/schema/account/secrets.
- `make quotas CLUSTER=<cluster>`: checks AWS EC2 vCPU quotas vs current usage for the instance types in `cluster.yaml`.
  - Also runs automatically from:
    - `scripts/cluster-create.sh`
    - `scripts/spot-workers.sh`
  - Override: `SKIP_QUOTAS=1`
- `make spot-workers CLUSTER=<cluster>`: patches **installer-created worker MachineSets** to Spot and scales them to `.openshift.compute_replicas`.

### Recent changes (for traceability)

- `ca659e6` — `feat(scripts): add AWS EC2 quota checks`
  - Adds `scripts/aws-quotas.sh` + Make targets `quotas` / `quotas-all`.
- `7e2b1c4` — `docs: clarify MachineSet ownership`
  - Documents: baseline worker MachineSets are installer-owned; specialized pools/operators belong in GitOps.

### Key limitation to keep in mind

`scripts/aws-quotas.sh` only knows about instance types in `clusters/<cluster>/cluster.yaml` (control plane + baseline compute). If GitOps adds new pools (GPU/Inf), quotas for those families must be checked separately (manual AWS quota check or future enhancement to the script/schema).

---

## Decision: What Lives in GitOps vs Clusters

### `signeting/clusters` owns

- Day‑0: cloud prereqs + `openshift-install` create/destroy.
- Day‑1: handoff/bootstrap + one-time posture changes (example: converting baseline workers to Spot).
- External guardrails:
  - AWS account hard check (must match `153526447089`).
  - Quota sanity checks before create/scale.

### `bitiq-io/gitops` owns (what you’ll implement)

- Ongoing **capacity primitives**:
  - Additional MachineSets for GPU and/or Inferentia pools.
  - Node labels/taints and policy for scheduling onto those pools.
  - Autoscaling resources (ClusterAutoscaler + MachineAutoscaler), if desired.
- Operators/config required for accelerators:
  - NVIDIA GPU Operator (and its supporting components).
  - Inferentia/Neuron components (if feasible on OpenShift/RHCOS).
- Drift detection + reconciliation via Argo CD.

---

## Requirements / Success Criteria

### GPU (NVIDIA) pool

1. GitOps declares at least one GPU MachineSet (or a small set for diversification), in `openshift-machine-api`.
2. Nodes from that MachineSet:
   - Join the cluster and become `Ready`.
   - Are clearly identifiable via labels (and optionally taints).
3. NVIDIA GPU Operator is installed and reports healthy.
4. A test pod can schedule onto the GPU nodes and sees allocatable GPUs (e.g., `nvidia.com/gpu`).

### Inferentia pool (optional, gated)

1. Confirm feasibility/support for Inferentia (Neuron) on OpenShift/RHCOS in this environment.
2. If feasible, GitOps declares an Inferentia MachineSet and installs the required Neuron components.
3. A test workload can detect/use Neuron devices.

### Safety

- Argo CD must not accidentally delete MachineSets (no surprise node deletion).
- If autoscaling is enabled, Argo CD must not “fight” the autoscaler.
- Quota checks must be performed before scaling new instance families.

---

## High-Level Implementation Plan (for the GitOps agent)

### Phase 0 — Gather cluster facts (no changes yet)

1. Get `infraID` / infrastructure name (needed for MachineSet selectors/labels):
   - `oc get infrastructures.config.openshift.io/cluster -o jsonpath='{.status.infrastructureName}{"\n"}'`
2. Inspect existing MachineSets to use as a template:
   - `oc -n openshift-machine-api get machinesets`
   - `oc -n openshift-machine-api get machineset <existing> -o yaml > /tmp/ms.yaml`
3. Confirm AWS quota headroom for the intended families:
   - From this repo (baseline only): `make quotas CLUSTER=prod`
   - For new families (GPU/Inf): use AWS Service Quotas directly (see Appendix).

Deliverable: record `infraID`, region/AZ, and chosen instance types (GPU/Inf).

### Phase 1 — Create a “capacity” GitOps surface with safety rails

Implement a GitOps structure that clearly separates capacity primitives from app workloads:

- Create a dedicated Argo CD app (or app-of-apps child) for “capacity” resources.
- Recommended defaults for this capacity app:
  - **Disable auto-prune** (or require manual sync for deletes) to avoid accidental node pool deletion.
  - Consider disabling auto-sync initially; enable once stable.
  - If autoscalers will mutate `.spec.replicas`, add `ignoreDifferences` for `MachineSet.spec.replicas`.

Deliverable: Argo CD app wiring for capacity resources, safe by default.

### Phase 2 — Add GPU MachineSet(s)

Approach: copy an existing worker MachineSet and modify only what’s needed.

Minimum changes:

- MachineSet name: include a GPU suffix (but keep the correct `infraID` prefix).
- `.spec.selector.matchLabels` and `.spec.template.metadata.labels`:
  - Must include the correct `machine.openshift.io/cluster-api-cluster: <infraID>`.
  - Use a distinct machineset label value for uniqueness.
- ProviderSpec:
  - Set `instanceType` to the chosen GPU instance type (e.g., `g5.2xlarge`).
  - Set Spot options if the pool should be Spot.
- Node labels/taints:
  - Add a node label that GitOps and workloads can target (example: `node-role.kubernetes.io/gpu: ""` or `node.signet.ing/pool: gpu`).
  - Add a taint (recommended) so only GPU workloads land here by default (example key: `nvidia.com/gpu`, effect: `NoSchedule`).

Scaling:

- Start at `replicas: 0` (safe), then scale to `1` to validate end-to-end.
- If using autoscaling, add `MachineAutoscaler` (min=0, max=N) and ensure ClusterAutoscaler exists/configured.

Deliverable: GPU MachineSet applied and able to create nodes.

### Phase 3 — Install and configure NVIDIA GPU Operator

Implement via the existing GitOps pattern for operators in this repo:

- Add `Subscription` (and any `OperatorGroup` if needed) for NVIDIA GPU Operator.
- Add the operator’s configuration CR (commonly `ClusterPolicy`).
- Ensure the operator’s DaemonSets target only GPU nodes:
  - Use `nodeSelector` and tolerations that match your GPU labels/taints.

Deliverable: operator is healthy; GPU driver/device plugin running on GPU nodes.

### Phase 4 — Validation and “hello world” GPU workload

1. Confirm allocatable GPUs:
   - `oc describe node <gpu-node> | rg -n \"nvidia.com/gpu|Allocatable\"`
2. Run a minimal CUDA sample pod that requests a GPU and tolerates the taint.

Deliverable: a reproducible validation manifest and a short runbook note.

### Phase 5 — Inferentia feasibility gate (do not skip)

Before writing manifests:

- Confirm whether Inferentia (Neuron) is supported on OpenShift/RHCOS in this environment.
  - Identify the supported method to install Neuron drivers/runtime on worker nodes.
  - Identify the correct Kubernetes device plugin/operator (if any) that works on OCP.

If feasible:

- Add an Inferentia MachineSet (distinct labels/taints, min replicas 0).
- Add the Neuron device plugin/runtime components, scoped to only those nodes.
- Validate allocatable devices and run a test workload.

If not feasible:

- Document the blocker and propose alternatives (GPU-only, or a different node OS/approach).

Deliverable: either working Inferentia pool or a clearly documented “not supported here” outcome.

### Phase 6 — Documentation and operational notes in GitOps

Add/extend docs in `bitiq-io/gitops`:

- How to scale GPU/Inf pools (manual vs autoscaled).
- How taints/labels work; how workloads target these nodes.
- Safety note about Argo CD pruning and capacity resources.
- Dependency ordering (MachineSet first vs operator first, and why).

---

## Interactions / Conflicts to Avoid

1. **Do not let a “baseline spot workers” script affect specialized pools.**
   - `signeting/clusters/scripts/spot-workers.sh` targets MachineSets whose machine-role label is `worker`.
   - For specialized pools, prefer a distinct machine-role (e.g., `gpu`, `inferentia`) while still labeling the Node as `worker` if desired.
2. **Don’t use Argo CD prune casually on MachineSets.**
   - Deleting a MachineSet can delete Nodes (and disrupt workloads).
3. **If autoscaling is enabled, Argo should not fight replica counts.**
   - Use `ignoreDifferences` on MachineSet replicas, and let autoscalers drive scaling.

---

## Appendix

### A. AWS EC2 quota categories (vCPU-based)

- GPU families `g*` (and `vt*`) are counted under **G and VT**.
- Inferentia `inf*` is counted under **Inf**.
- Trainium `trn*` is counted under **Trn**.
- Baseline CPU families (m/r/c/etc.) are typically **Standard**.

To list quotas in a region (manual check):

```bash
AWS_PROFILE=signet aws service-quotas list-service-quotas \
  --service-code ec2 \
  --region us-west-2 \
  --output json \
  | jq -r '.Quotas[]
    | select(.QuotaName | test("Running On-Demand|Spot Instance Requests"))
    | [.QuotaName, (.Value|tostring)]
    | @tsv' \
  | sort
```

### B. How to get the cluster `infraID`

```bash
oc get infrastructures.config.openshift.io/cluster \
  -o jsonpath='{.status.infrastructureName}{"\n"}'
```

### C. Where kubeconfig lives in `signeting/clusters`

- Normalized kubeconfig path after install:
  - `clusters/<cluster>/.work/kubeconfig`

### D. Suggested initial defaults (if you need a starting point)

- GPU instance type: `g5.2xlarge` (A10G) in `us-west-2a`, Spot, replicas 0 → 1 for validation.
- GPU node label: `node-role.kubernetes.io/gpu: ""`
- GPU node taint: `nvidia.com/gpu=true:NoSchedule`
- Inferentia: start with a feasibility check for `inf2.xlarge` + Neuron support before writing manifests.


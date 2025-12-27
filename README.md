# Signet clusters

Day‑0 OpenShift cluster provisioning + Day‑1 GitOps handoff.

This repo creates/destroys OpenShift clusters (starting with AWS) and then bootstraps the existing GitOps repo (`bitiq-io/gitops`) onto the cluster so Day‑2 operations are fully GitOps-driven.

---

## What lives where

| Concern | `clusters` (this repo) | `bitiq-io/gitops` |
|---|---:|---:|
| Cloud prerequisites (DNS, IAM, state backends) | ✅ | ❌ |
| Cluster lifecycle (create/destroy) | ✅ | ❌ |
| Installing OpenShift (AWS IPI via `openshift-install`) | ✅ | ❌ |
| Bootstrap GitOps onto a fresh cluster | ✅ | ✅ (via `scripts/bootstrap.sh`) |
| Operators, namespaces, policies, workloads | ❌ | ✅ |
| Day‑2 ops (rollouts, upgrades, drift control) | ❌ | ✅ |

The guiding idea: **don’t “abstract” clouds—isolate them**. The portable platform is OpenShift + GitOps; the cloud layer is thin scaffolding that we can throw away when credits/constraints change.

---

## Quick start

### 0) Prereqs

Local tools:

- `aws` CLI v2
- `terraform` (or OpenTofu, but start with Terraform for compatibility)
- `oc`
- `openshift-install` (matching your target OCP version)
- `jq`
- `yq` (recommended; scripts assume it unless we replace with a small Go helper)

You also need:

- A Red Hat pull secret (JSON)  
- An SSH public key for node access

### 1) Clone repos

```bash
git clone https://github.com/bitiq-io/clusters.git
cd clusters
```

You should also have:

```bash
git clone https://github.com/bitiq-io/gitops.git ../gitops
```

(Our bootstrap step will clone automatically too, but having it nearby makes debugging easier.)

### 2) Configure AWS profile for Signet

**Guardrail target AWS account:** `153526447089`

```bash
export AWS_PROFILE=signet
aws sts get-caller-identity
# Account must be 153526447089
```

If this prints a different account, stop. Fix your AWS profile before proceeding.

### 3) Create a cluster definition

Copy the example:

```bash
cp -r clusters/_example/aws-single-az clusters/signet-aws-prod
```

Edit:

- `clusters/signet-aws-prod/cluster.yaml`

### 4) Put secrets in the expected place

```bash
mkdir -p secrets/signet-aws-prod
cp /path/to/pull-secret.json secrets/signet-aws-prod/pull-secret.json
cp ~/.ssh/id_ed25519.pub secrets/signet-aws-prod/ssh.pub
```

These are **gitignored**. Never commit them.

### 5) Run the workflow

```bash
export CLUSTER=signet-aws-prod

make preflight        CLUSTER=$CLUSTER
make tf-bootstrap     CLUSTER=$CLUSTER   # one-time per AWS account (state bucket)
make tf-apply         CLUSTER=$CLUSTER   # DNS + IAM prereqs
make cluster-create   CLUSTER=$CLUSTER   # openshift-install create cluster
make bootstrap-gitops CLUSTER=$CLUSTER   # runs gitops/scripts/bootstrap.sh
make verify           CLUSTER=$CLUSTER
```

### 6) Use the cluster

After `cluster-create`, the kubeconfig lives at:

- `clusters/<cluster>/.work/kubeconfig` (this repo’s normalized output)
- The installer’s original kubeconfig also exists under `clusters/<cluster>/.work/installer/auth/kubeconfig`

Example:

```bash
export KUBECONFIG=clusters/signet-aws-prod/.work/kubeconfig
oc get nodes
```

---

## Architecture

### Provisioning + handoff flow

```mermaid
flowchart LR
  subgraph C["clusters repo (Day-0 + Day-1)"]
    A[cluster.yaml] --> P[preflight (account/tool checks)]
    A --> T[terraform prereqs<br/>DNS + IAM + state]
    A --> R[render install-config.yaml]
    R --> I[openshift-install<br/>create cluster]
    I --> B[bootstrap GitOps]
  end

  subgraph G["bitiq-io/gitops (Day-1/Day-2)"]
    S[./scripts/bootstrap.sh<br/>ENV + BASE_DOMAIN] --> AR[Argo CD apps/ApplicationSets]
    AR --> O[Operators + platform services]
    AR --> W[Signet workloads]
  end

  B --> S
```

### “Thin cloud layer” strategy

```mermaid
flowchart TB
  subgraph Portable["Portable layers (should move clouds unchanged)"]
    K[OpenShift API + platform features] --> X[GitOps repo (apps/operators/policies)]
  end

  subgraph Cloud["Disposable cloud layer (rewrite per cloud)"]
    AWS[AWS: IAM + Route53 + state backend]
    AZ[Azure: Entra ID + DNS + state backend]
    GCP[GCP: IAM + Cloud DNS + state backend]
  end

  AWS --> K
  AZ --> K
  GCP --> K
```

---

## Repository structure

```text
.
├── clusters/
│   ├── _example/
│   │   └── aws-single-az/
│   │       ├── cluster.yaml
│   │       └── install-config.yaml.tmpl
│   └── signet-aws-prod/
│       ├── cluster.yaml
│       ├── install-config.yaml.tmpl
│       └── .work/                  # generated (gitignored)
├── secrets/
│   └── <cluster>/                  # pull-secret.json, ssh.pub (gitignored)
├── platforms/
│   └── aws/
│       └── terraform/
│           ├── bootstrap/          # one-time account setup (state bucket)
│           └── prereqs/            # per-cluster prereqs (DNS, IAM)
├── scripts/
│   ├── preflight.sh
│   ├── validate.sh
│   ├── tf-bootstrap.sh
│   ├── tf-apply.sh
│   ├── render-install-config.sh
│   ├── cluster-create.sh
│   ├── cluster-destroy.sh
│   ├── bootstrap-gitops.sh
│   └── verify.sh
├── schemas/
│   └── cluster.schema.json
├── docs/
│   ├── ARCHITECTURE.md
│   └── TROUBLESHOOTING.md
├── Makefile
└── README.md
```

---

## The cluster contract: `cluster.yaml`

`clusters/<name>/cluster.yaml` is the **single source of truth** for cluster intent.

Example (AWS, single-AZ):

```yaml
name: signet-aws-prod
env: prod

platform:
  type: aws
  account_id: "153526447089"
  region: us-west-2
  zones: ["us-west-2a"]  # single AZ default to avoid cross-AZ transfer costs

dns:
  # We recommend delegating a cloud subdomain (e.g. aws.signet.ing) for portability.
  base_domain: aws.signet.ing
  # If you manage the zone elsewhere, you can set hosted_zone_id and skip creation.
  # hosted_zone_id: "Z123..."

openshift:
  version: "4.20"
  control_plane_replicas: 3
  compute_replicas: 2
  instance_type_control_plane: m6i.large
  instance_type_compute: m6i.xlarge

credentials:
  aws_profile: signet
  cco_mode: mint   # mint (MVP) | manual-sts (roadmap)

gitops:
  repo_url: "https://github.com/bitiq-io/gitops.git"
  repo_ref: "main"
  env: prod
```

---

## Guardrails and safety

This repo is designed to prevent expensive mistakes:

- **Account hard check:** scripts fail if `aws sts get-caller-identity` does not match `cluster.yaml: platform.account_id`.
- **Terraform guardrail:** Terraform AWS provider uses `allowed_account_ids = [platform.account_id]`.
- **No secrets in git:** pull secret, ssh keys, kubeconfig, kubeadmin password, and install logs are all gitignored.
- **Destructive actions require confirmation:** `cluster-destroy` prompts you to type the cluster name.

---

## AWS notes

### Single-AZ vs multi-AZ

We default to **single-AZ** for cost control. Multi-AZ costs often show up as cross-AZ data transfer (control plane replication + service traffic + app chatter). When uptime needs win over cost, switch to multi-AZ by setting multiple zones in `cluster.yaml`.

### DNS

For AWS IPI installs, plan for Route53 public DNS ownership of the cluster’s domain or delegated subdomain (this repo can manage the hosted zone, or you can point at an existing one via `hosted_zone_id`).

### Credentials

MVP uses `cco_mode: mint` for simplicity. Roadmap adds `manual-sts` to avoid long-lived cloud creds living in the cluster.

---

## Make targets

| Target | Purpose |
|---|---|
| `make preflight` | verify tools + verify AWS account |
| `make validate` | validate `cluster.yaml` against JSON schema |
| `make tf-bootstrap` | one-time: create state bucket/backend |
| `make tf-apply` | per cluster: DNS + IAM prereqs |
| `make cluster-create` | create OCP cluster via `openshift-install` |
| `make bootstrap-gitops` | call `bitiq-io/gitops/scripts/bootstrap.sh` |
| `make verify` | health checks (nodes, operators, gitops) |
| `make cluster-destroy` | destroy cluster via `openshift-install destroy` |

---

## Troubleshooting (short version)

- **“Wrong AWS account”**: set `AWS_PROFILE=signet` and rerun `make preflight`.
- **DNS doesn’t resolve yet**: hosted zone delegation can take time; verify NS records.
- **Installer failed mid-run**: run `make cluster-destroy`, fix the cause, retry.
- **GitOps bootstrap fails**: confirm `gitops/scripts/bootstrap.sh` runs manually with:
  `ENV=prod BASE_DOMAIN=apps.<cluster>.<base_domain> ./scripts/bootstrap.sh`

More in `docs/TROUBLESHOOTING.md`.

---

## Roadmap

- `cco_mode: manual-sts` for short-lived credentials on AWS (and analogous workload identity on Azure/GCP).
- Azure and GCP implementations under `platforms/azure` and `platforms/gcp`.
- Agent-based installer support for on-prem / airgapped environments.

---

## References

- OpenShift 4.20 install on AWS: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/installing_on_aws/index
- OpenShift cloud credentials (CCO): https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/managing-cloud-provider-credentials
- GitOps bootstrap repo: https://github.com/bitiq-io/gitops (see `./scripts/bootstrap.sh`)

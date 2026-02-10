# PLAN

Concrete implementation plan to make the `clusters` repo fully functional and aligned with `bitiq-io/gitops`.

This plan is written so an AI coding agent can implement it end-to-end with minimal guesswork.

---

## Goals

1. **Create/destroy OpenShift clusters** (AWS first) in a repeatable, audited way.
2. **Handoff to GitOps** by invoking `bitiq-io/gitops/scripts/bootstrap.sh` with the correct `ENV` and `BASE_DOMAIN`.
3. **Prevent expensive mistakes** (wrong AWS account, leaked secrets, orphaned infra).
4. Keep the design **cloud-portable** by using a stable `cluster.yaml` contract and isolating provider-specific code.

---

## Non-goals (MVP)

- UPI (user-provisioned infra) for OpenShift.
- Full multi-cloud implementation (Azure/GCP will be stubs until AWS is solid).
- Rewriting the `gitops` repo structure (we integrate with its current contract).

---

## Current status

- Repo skeleton is in place (directories, `.gitignore`, Makefile, script stubs).
- Schema + example cluster template are in place (`schemas/cluster.schema.json`, `clusters/_example/...`).
- Preflight is in place (`scripts/preflight.sh`) with tool checks, schema validation, account guardrail, and secrets checks.
- Terraform bootstrap/prereqs roots + scripts are in place (`platforms/aws/terraform/...`, `scripts/tf-*.sh`).
- Install-config renderer is in place (`scripts/render-install-config.sh`).
- Cluster create/destroy, GitOps bootstrap, and verify scripts are in place (`scripts/cluster-*.sh`, `scripts/bootstrap-gitops.sh`, `scripts/verify.sh`).
- Docs runbooks and CI workflow are in place (`docs/*.md`, `.github/workflows/ci.yml`).
- Manual STS doc + prototype script are in place (`docs/CCO_MANUAL_STS.md`, `scripts/cco-manual-sts.sh`).
- Next focus: Milestone 8 validation on a throwaway cluster.

---

## Repo conventions

### Source of truth
- `clusters/<cluster>/cluster.yaml` is the **only** declarative cluster intent.
- Everything else is generated from it.

### Generated outputs
- `clusters/<cluster>/.work/` contains:
  - rendered `install-config.yaml`
  - installer directory + logs
  - `kubeconfig` copy and pointers
  - metadata files and timestamps

This directory is gitignored.

### Secrets
- `secrets/<cluster>/pull-secret.json`
- `secrets/<cluster>/ssh.pub`

Also gitignored.

### Guardrail account
- Signet AWS account ID: **153526447089**
- Scripts hard-fail if `aws sts get-caller-identity` doesn’t match.

---

## MVP success criteria (Definition of Done)

- `make preflight CLUSTER=<cluster>` fails fast if:
  - required tools are missing
  - AWS account mismatch
  - secrets missing
  - cluster.yaml invalid

- `make cluster-create CLUSTER=<cluster>` results in:
  - `clusters/<cluster>/.work/kubeconfig` exists
  - `oc --kubeconfig ... get nodes` shows expected nodes Ready
  - `oc get co` converges to Available=True (eventually)

- `make bootstrap-gitops CLUSTER=<cluster>` results in:
  - GitOps operator and apps installed by `gitops/scripts/bootstrap.sh`
  - Argo resources appear (apps/applicationsets) in expected namespaces

- `make cluster-destroy CLUSTER=<cluster>`:
  - destroys the cluster via `openshift-install destroy cluster`
  - does not delete shared prereqs unless explicitly asked (separate lifecycle)

---

## Milestone 0 — Repo skeleton + developer ergonomics

### Task 0.1 — Create initial directory structure + git hygiene
**Why:** Predictable structure prevents sprawl and makes automation stable.

**Work:**
- Create directories shown in README.
- Add `.gitignore` entries for:
  - `secrets/**`
  - `clusters/**/.work/**`
  - Terraform state, `.terraform/`, `.terraform.lock.hcl`
  - installer artifacts if any leak outside `.work`

**DoD:**
- `git status` stays clean after running `make preflight` (once implemented).

**Status:** done

---

### Task 0.2 — Makefile with stable UX
**Why:** `make` gives one stable interface for humans and CI.

**Work:**
- Implement `Makefile` targets:
  - `help`
  - `preflight`, `validate`
  - `tf-bootstrap`, `tf-apply`
  - `cluster-create`, `cluster-destroy`
  - `bootstrap-gitops`, `verify`

**DoD:**
- `make help` prints target list + required vars.
- Every target delegates to a script (`scripts/*.sh`) rather than embedding logic.

**Status:** done

---

## Milestone 1 — Cluster contract + validation

### Task 1.1 — Create JSON schema for `cluster.yaml`
**Why:** Prevent silent drift and misconfigurations (especially around account/region/zones).

**Work:**
- Create `schemas/cluster.schema.json` requiring:
  - `name`, `env`
  - `platform.type`, `platform.account_id`, `platform.region`, `platform.zones`
  - `dns.base_domain`
  - `openshift.version`, replicas, instance types
  - `credentials.aws_profile` (optional) and `credentials.cco_mode`
  - `gitops.repo_url`, `gitops.repo_ref`, `gitops.env` (enum: `local`, `sno`, `prod`)
- `scripts/validate.sh` uses `yq` + `jv` (auto-installs via `scripts/ensure-jv.sh`).

**DoD:**
- `scripts/validate.sh <cluster>` returns non-zero with clear errors on invalid YAML.

**Status:** done

---

### Task 1.2 — Create example cluster
**Why:** Humans need a “copy this and edit” path.

**Work:**
- Add `clusters/_example/aws-multi-az/cluster.yaml` (recommended baseline)
- Add `clusters/_example/aws-single-az/cluster.yaml` (cheap dev/throwaway option)
- Add matching `install-config.yaml.tmpl` (shared)

**DoD:**
- `cp -r clusters/_example/aws-multi-az clusters/test` is a working start (or `aws-single-az` for cheap throwaway).

**Status:** done

---

## Milestone 2 — Guardrails (account correctness + tool checks)

### Task 2.1 — Implement `scripts/preflight.sh`
**Why:** The fastest money leak is running terraform/install in the wrong AWS account.

**Work:**
- Inputs: `CLUSTER` name
- Steps:
  - Validate YAML (call `scripts/validate.sh`)
  - Check required commands: `aws terraform oc openshift-install helm jq yq go`
  - Ensure `jv` is available (install via `scripts/ensure-jv.sh` if missing)
  - Load `platform.account_id` and `credentials.aws_profile` from cluster.yaml
  - Run `aws sts get-caller-identity` under that profile and compare account ID
  - Ensure secrets exist in `secrets/<cluster>/`
  - Print a concise summary of what will happen next (region, zones, base domain)

**DoD:**
- Using a personal account profile causes a hard fail *before* any writes.

**Status:** done

---

## Milestone 3 — Terraform (AWS state + prereqs)

### Task 3.1 — Terraform “bootstrap” root (one-time per AWS account)
**Why:** Shared remote state avoids “who ran terraform last” chaos.

**Design choice:** Use S3 backend with **S3-native locking** (`use_lockfile = true`). Do **not** depend on DynamoDB locking.

**Work:**
- Directory: `platforms/aws/terraform/bootstrap/`
- Provider guardrail: `allowed_account_ids = [platform.account_id]` so Terraform fails fast in the wrong account.
- Creates:
  - S3 bucket with:
    - versioning enabled
    - encryption enabled
    - public access blocked
- Output: bucket name, region

**DoD:**
- `make tf-bootstrap` creates bucket and prints next steps.

**Status:** done

---

### Task 3.2 — Terraform “prereqs” root (per cluster)
**Why:** OpenShift install needs DNS and IAM prepared consistently.

**Work:**
- Directory: `platforms/aws/terraform/prereqs/`
- Backend: S3 using the bootstrap bucket and `use_lockfile = true`
- Provider guardrail: `allowed_account_ids = [platform.account_id]` to block wrong-account runs.
- Resources:
  - Route53 hosted zone (optional create vs use existing)
  - IAM role for provisioning (prefer assume-role over static access keys)
  - Standard tags for cost allocation (cluster name, env, managed-by)

**DoD:**
- `make tf-apply` produces outputs needed by renderer:
  - `hosted_zone_id`
  - (if created) name servers for delegation
  - role ARN (or documented credential source)

**Notes:**
- Start permissive (AdministratorAccess) if needed for MVP, but explicitly mark it as “tighten later”.

**Status:** done

---

## Milestone 4 — Render install-config + OpenShift install

### Task 4.1 — Implement `scripts/render-install-config.sh`
**Why:** Deterministic, repeatable installs with no secrets committed.

**Work:**
- Read cluster.yaml + terraform outputs.
- Read secrets from `secrets/<cluster>/`:
  - pull secret JSON
  - ssh public key
- Render `clusters/<cluster>/install-config.yaml.tmpl` into:
  - `clusters/<cluster>/.work/install-config.yaml`
- Ensure zones list matches `platform.zones` exactly.

**DoD:**
- Re-running renderer produces the same output (idempotent).
- Secrets do not leak into stdout.

**Status:** done

---

### Task 4.2 — Implement `scripts/cluster-create.sh`
**Why:** One command creates the cluster reliably.

**Work:**
- Call `preflight`
- Ensure `.work/installer/` exists and is empty or intentionally reused
- Copy rendered install-config into installer dir
- Run `openshift-install create cluster --dir ...`
- Copy kubeconfig to `clusters/<cluster>/.work/kubeconfig`

**DoD:**
- `oc --kubeconfig clusters/<cluster>/.work/kubeconfig get nodes` works.

**Status:** done

---

### Task 4.3 — Implement `scripts/cluster-destroy.sh`
**Why:** Clean teardown avoids bill surprises.

**Work:**
- Require a type-to-confirm prompt (cluster name)
- Call `preflight` (or a lighter “preflight-lite” that only checks account/tools)
- Run `openshift-install destroy cluster --dir ...`
- Optional cleanup of `.work/installer/` after destroy

**DoD:**
- Cluster resources are removed from AWS.

**Status:** done

---

## Milestone 5 — GitOps bootstrap integration

### Task 5.1 — Implement `scripts/bootstrap-gitops.sh`
**Why:** Remove tribal knowledge; “cluster is alive → GitOps takes over” should be one step.

**Work:**
- Requires kubeconfig output
- Ensure `helm` is installed (the gitops bootstrap script requires it).
- Set `KUBECONFIG=clusters/<cluster>/.work/kubeconfig` for the bootstrap call.
- Compute `BASE_DOMAIN` for gitops bootstrap:
  - `apps.<clusterName>.<dns.base_domain>` (match your OpenShift route convention)
- Clone `gitops.repo_url` at `gitops.repo_ref` into `clusters/<cluster>/.work/gitops-src/`
- Run:
  - `ENV=<gitops.env> BASE_DOMAIN=<computed> TARGET_REV=<gitops.repo_ref> GIT_REPO_URL=<gitops.repo_url> ./scripts/bootstrap.sh`
- Capture:
  - git commit SHA used
  - bootstrap timestamp
  - write a trace file under `clusters/<cluster>/.work/` (e.g., `gitops-bootstrap.json`)

**DoD:**
- `oc get ns openshift-gitops` exists after bootstrap (or equivalent per bootstrap script behavior).
- Argo resources exist and begin syncing.
- Trace file exists under `clusters/<cluster>/.work/` with repo URL/ref/SHA and timestamp.

**Status:** done

---

## Milestone 6 — Verification + troubleshooting docs

### Task 6.1 — Implement `scripts/verify.sh`
**Why:** Humans need fast, deterministic “is it healthy?” signals.

**Work:**
- Checks:
  - nodes Ready
  - clusteroperators available (or at least not degraded)
  - key namespaces exist (`openshift-gitops` if bootstrap enabled)
- Print a compact summary and where to look next if failing.

**DoD:**
- `make verify` returns non-zero on failure.

**Status:** done

---

### Task 6.2 — Minimal runbooks
**Why:** Reduce reruns and guesswork.

**Work:**
- `docs/TROUBLESHOOTING.md`:
  - DNS propagation checks
  - common installer failures
  - GitOps bootstrap failures
  - where logs live under `.work/`
- `docs/ARCHITECTURE.md`:
  - explain contract + why it’s portable

**DoD:**
- Human can follow docs to recover from the top 5 failure modes without Slack archaeology.

**Status:** done

---

## Milestone 7 — CI hygiene (recommended)

### Task 7.1 — GitHub Actions lint + validate
**Why:** Infra repos rot fast without automation.

**Work:**
- Add workflow to run:
  - `shellcheck scripts/*.sh`
  - `terraform fmt -check` and `terraform validate` for AWS roots
  - schema validation for example clusters

**DoD:**
- CI fails fast on formatting/validation errors (push + PR).

**Status:** done

---

## Milestone 8 — Credentials hardening (roadmap)

### Task 8.1 — Add `cco_mode: manual-sts` support (AWS STS)
**Why:** Reduce long-lived cloud credentials and improve multi-cloud posture.

**Work (design + prototype):**
- Document:
  - required AWS OIDC resources
  - how `ccoctl` is invoked
  - what manifests are generated and where stored
- Prototype script path (even if behind a feature flag).

**DoD:**
- Documented process + spike branch working on a throwaway cluster.

**Status:** in progress (docs + prototype script done; cluster validation pending)

---

## Implementation order

1. Milestone 0–2 (skeleton + validation + preflight)
2. Milestone 3 (terraform bootstrap + prereqs)
3. Milestone 4 (render + create/destroy cluster)
4. Milestone 5 (GitOps bootstrap handoff)
5. Milestone 6 (verify + docs)
6. Milestone 7+ (CI + credential hardening)

---

## Agent sanity checks

- Before applying anything: `make preflight`
- Before running installer: confirm `dns.base_domain` resolves via hosted zone
- After install: `oc get nodes`, `oc get co`
- After bootstrap: `oc get ns openshift-gitops` and check Argo UI/objects

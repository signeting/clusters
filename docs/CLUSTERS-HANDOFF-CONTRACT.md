# Clusters ↔ GitOps Handoff Contract

Scope: Day-1 bootstrap only. Day-2 operations (operators, workloads, capacity primitives like GPU MachineSets) are owned by `bitiq-io/gitops`.

## Canonical bootstrap entrypoint

Even if you are actively working inside `bitiq-io/gitops`, the canonical way to bootstrap GitOps onto a new cluster is to run it from this repo:

```bash
make bootstrap-gitops CLUSTER=<cluster>
```

Reason: `scripts/bootstrap-gitops.sh` is the stable interface that:
- Derives `ENV` and `BASE_DOMAIN` from `clusters/<cluster>/cluster.yaml`.
- Clones the GitOps repo at the requested `gitops.repo_ref` into `clusters/<cluster>/.work/gitops-src/`.
- Optionally configures external Vault Kubernetes auth for the new cluster (when `VAULT_ADDR`/`VAULT_TOKEN` are set).
- Ensures Argo CD has repo credentials for private repos (env vars, Vault KV, or local git credential helper).
- Writes a trace file to `clusters/<cluster>/.work/gitops-bootstrap.json` for auditability and debugging.

Running `bitiq-io/gitops/scripts/bootstrap.sh` directly is supported for debugging, but it is not the canonical path (avoids having two “bootstrap workflows” that drift over time).

## Inputs (source of truth)

From `clusters/<cluster>/cluster.yaml`:
- `name`
- `dns.base_domain` (used to compute `BASE_DOMAIN=apps.<name>.<dns.base_domain>`)
- `gitops.env` (passed as `ENV`)
- `gitops.repo_url`
- `gitops.repo_ref`

## Required runtime env (depends on setup)

Repo credentials (private `gitops.repo_url`):
- Preferred: store in Vault KV at `gitops/github/gitops-repo` (override via `GITOPS_REPO_VAULT_PATH`).
- Or export: `GITOPS_REPO_USERNAME` + `GITOPS_REPO_PASSWORD` (or `GITOPS_REPO_PAT`).
- Or rely on the local git credential helper.

External Vault (for VCO/VSO in GitOps repo):
- `VAULT_ADDR` (example: `https://vault.bitiq.io:8200`)
- `VAULT_TOKEN` (token permitted to update `auth/<mount>/config`)
- Optional: `VAULT_K8S_AUTH_MOUNT` to use a dedicated auth mount per env/cluster.

## Outputs (gitignored)

This repo’s normalized kubeconfig:
- `clusters/<cluster>/.work/kubeconfig`

GitOps working copy (cloned by bootstrap):
- `clusters/<cluster>/.work/gitops-src/`

Trace output:
- `clusters/<cluster>/.work/gitops-bootstrap.json`

## Recreate considerations (`infraID`)

On every cluster recreate, the installer `infraID` changes. Any GitOps-managed MachineSet manifests that hardcode an old `infraID` (names, labels, AWS tags, etc.) are expected to break.

Recommendation: template/inject the live `infraID` during bootstrap (or derive from the baseline worker MachineSets) rather than committing static `infraID` values.

## Debugging (non-canonical)

If you need to debug the GitOps bootstrap implementation, run it in the cloned workdir:

```bash
cd "clusters/<cluster>/.work/gitops-src"
KUBECONFIG="../kubeconfig" ENV=<gitops.env> BASE_DOMAIN="apps.<cluster>.<dns.base_domain>" ./scripts/bootstrap.sh
```

Use this only for investigation; the canonical workflow remains `make bootstrap-gitops CLUSTER=<cluster>`.


# AGENTS.md - Signet Clusters Repository

Purpose: Guide AI/dev assistants working in this repo (Day-0 cluster provisioning + Day-1 GitOps handoff). This repo creates/destroys OpenShift clusters and bootstraps the GitOps repo; it does not manage Day-2 workloads.

## Golden Rules (safety + portability)

- `clusters/<cluster>/cluster.yaml` is the single source of truth. Everything else is rendered or derived from it.
- Do not commit secrets, kubeconfigs, or installer artifacts. Secrets live only under `secrets/<cluster>/` and outputs only under `clusters/<cluster>/.work/` (gitignored).
- Hard guardrail: AWS account ID must match `platform.account_id` (Signet: `153526447089`). Scripts must fail before any writes if the account mismatches.
- Use the Makefile targets that delegate to `scripts/*.sh`. Keep logic in scripts, not the Makefile.
- Keep the cloud layer thin and disposable (DNS/IAM/state only). Do not add Day-2 workload management here; that belongs in `bitiq-io/gitops`.

## Repo Contract (what must stay true)

- Cluster intent lives in `clusters/<cluster>/cluster.yaml` and validates against `schemas/cluster.schema.json`.
- Generated data lives in `clusters/<cluster>/.work/` (rendered install-config, installer logs, kubeconfig).
- Terraform roots are split:
  - `platforms/aws/terraform/bootstrap/` for one-time state backend setup
  - `platforms/aws/terraform/prereqs/` for per-cluster DNS/IAM prereqs
- Scripts are the API:
  - `scripts/preflight.sh` checks tools, account, secrets, and schema validation
  - `scripts/render-install-config.sh` renders `install-config.yaml`
  - `scripts/cluster-create.sh` and `scripts/cluster-destroy.sh` wrap `openshift-install`
  - `scripts/bootstrap-gitops.sh` hands off to the GitOps repo
  - `scripts/verify.sh` reports cluster health

## GitOps Handoff Contract

- The GitOps repo is `https://github.com/bitiq-io/gitops`. Do not edit it from here unless explicitly asked.
- `scripts/bootstrap-gitops.sh` must:
  - Clone `gitops.repo_url` at `gitops.repo_ref` into `clusters/<cluster>/.work/gitops-src/`
  - Run `ENV=<gitops.env> BASE_DOMAIN=apps.<cluster>.<dns.base_domain> ./scripts/bootstrap.sh`
  - Record the Git SHA and timestamp for traceability
- Valid `ENV` values in gitops are `local`, `sno`, and `prod`. This repo should default to `prod` for real clusters unless directed otherwise.

## Git and Release Rules (SemVer + Conventional Commits)

- Use Conventional Commits: `type(scope): subject` (imperative). Example: `feat(scripts): add preflight account guard`.
- Recommended types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `build`.
- Scope should match the surface area: `scripts`, `platforms/aws`, `schemas`, `docs`, `clusters`, `make`, `ci`.
- Commit after each completed task/milestone using Conventional Commits. If the worktree has unrelated changes or the task is only partially complete, ask before committing.
- Tag releases as `vX.Y.Z` (SemVer).
  - Major: breaking changes to `cluster.yaml` schema, Make targets, or workflow contracts.
  - Minor: new capabilities or provider support that do not break existing flows.
  - Patch: fixes, maintenance, and doc-only changes.
- Keep branches and PRs single-purpose; avoid mixing unrelated changes.

## Branch Naming

- Use short, purpose-focused names: `docs/...`, `feat/...`, `fix/...`, `chore/...`, `ci/...`.
- Include scope if helpful: `feat/scripts-preflight`, `fix/aws-prereqs`.

## Remote Sync (best practice)

- Pull or fetch/rebase before starting work to avoid diverging histories.
- Do not force-push to shared branches (`main`); open a PR or coordinate first.
- Keep local `main` in sync with `origin/main` before tagging releases.

## Release Checklist (lightweight)

- Confirm `README.md` and `PLAN.md` match any workflow or contract changes.
- Ensure examples still validate against the schema.
- Tag with `vX.Y.Z` and include a brief release note in the tag message.

## Change Hygiene (docs + examples)

- If `schemas/cluster.schema.json` changes, update example clusters and templates so they stay valid.
- If scripts or Make targets change, update `README.md` and `PLAN.md` where they describe the workflow or contract.
- If GitOps handoff logic changes, sanity-check against `bitiq-io/gitops` bootstrap expectations.
- For Mermaid diagrams in `README.md`, quote any label that includes punctuation or special characters (e.g., `/`, `+`, `(`, `)`, `:`) to keep GitHub rendering happy.

## Validation and Expected Checks

- Always run `make preflight CLUSTER=<cluster>` before changes that write to cloud resources.
- Schema validation should fail fast on invalid `cluster.yaml` (clear errors, non-zero exit).
- `make verify CLUSTER=<cluster>` should confirm nodes are Ready and cluster operators are Available.
- Prefer `shellcheck` for scripts and keep bash strictness (set -euo pipefail) unless a specific script justifies exceptions.

## Anti-Patterns (avoid)

- Editing generated files under `.work/` directly.
- Bypassing guardrails (running terraform or installer without account checks).
- Storing credentials in repo files or in terraform variables.
- Adding workload operators or app manifests here instead of the GitOps repo.

## Why These Rules (reasoning)

- Cost and blast-radius control: wrong-account mistakes are expensive and hard to undo, so preflight must fail before any writes.
- Security: secrets, kubeconfigs, and pull secrets must never land in git; they are handled via explicit local paths and gitignore.
- Portability: the cloud layer is disposable; OpenShift + GitOps are the portable platform. Keep the contract stable and cloud-specific code thin.
- Reproducibility: scripts and Make targets provide deterministic, reviewable workflows; generated artifacts stay out of source control.
- Clear ownership: Day-0/Day-1 logic lives here, Day-2 workloads and policies live in `bitiq-io/gitops`.

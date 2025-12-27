# Architecture

## Overview

This repo handles Day-0 cluster provisioning and Day-1 GitOps handoff. Day-2 workloads and policies live in `bitiq-io/gitops`.

- Day-0: Terraform prereqs + `openshift-install` create/destroy.
- Day-1: bootstrap GitOps so Argo CD takes over.
- Day-2: out of scope here.

## Contract

- `clusters/<cluster>/cluster.yaml` is the single source of truth.
- Schema lives in `schemas/cluster.schema.json`.
- Secrets live in `secrets/<cluster>/` and are never committed.
- Generated outputs live in `clusters/<cluster>/.work/` and are gitignored.

## Provisioning flow

1. `make preflight` validates tools, schema, account, and secrets.
2. `make tf-bootstrap` creates the shared Terraform state bucket.
3. `make tf-apply` provisions DNS and IAM prereqs per cluster.
4. `make render-install-config` (invoked by create) renders `install-config.yaml`.
5. `make cluster-create` runs `openshift-install create cluster`.
6. `make bootstrap-gitops` runs the GitOps handoff script.
7. `make verify` checks nodes, operators, and GitOps namespace.

## AWS Terraform layout

- `platforms/aws/terraform/bootstrap/` creates the state bucket.
- `platforms/aws/terraform/prereqs/` creates Route53 and IAM prereqs.
- Guardrail: `allowed_account_ids = [platform.account_id]` blocks wrong-account runs.

## Scripts as API

All automation flows through `scripts/*.sh`:

- `scripts/preflight.sh`
- `scripts/validate.sh`
- `scripts/tf-bootstrap.sh`
- `scripts/tf-apply.sh`
- `scripts/render-install-config.sh`
- `scripts/cco-manual-sts.sh`
- `scripts/cluster-create.sh`
- `scripts/cluster-destroy.sh`
- `scripts/bootstrap-gitops.sh`
- `scripts/verify.sh`

## GitOps handoff

- Clones `gitops.repo_url` at `gitops.repo_ref` into `clusters/<cluster>/.work/gitops-src/`.
- Runs `ENV=<gitops.env> BASE_DOMAIN=apps.<cluster>.<dns.base_domain> ./scripts/bootstrap.sh`.
- Writes a trace file to `clusters/<cluster>/.work/gitops-bootstrap.json`.

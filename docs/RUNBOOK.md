# Runbook

This runbook is cloud-agnostic. Provider-specific details live in their sections.
Scope: Day-0 provisioning and Day-1 GitOps handoff only.

## Inputs and outputs (all clouds)

- Source of truth: `clusters/<cluster>/cluster.yaml`
- Secrets (gitignored): `secrets/<cluster>/pull-secret.json`, `secrets/<cluster>/ssh.pub`
- Generated outputs (gitignored): `clusters/<cluster>/.work/`

## Common workflow (all clouds)

1. Create a cluster definition
   - Copy the provider example under `clusters/_example/`.
   - Edit `clusters/<cluster>/cluster.yaml`.
2. Add secrets
   - Place the pull secret JSON and SSH public key under `secrets/<cluster>/`.
3. Preflight
   - `make preflight CLUSTER=<cluster>`
4. Provision cloud prereqs
   - `make tf-bootstrap CLUSTER=<cluster>` (one-time per cloud account)
   - `make tf-apply CLUSTER=<cluster>` (per cluster)
5. Create the cluster
   - `make cluster-create CLUSTER=<cluster>`
6. Handoff to GitOps
   - `make bootstrap-gitops CLUSTER=<cluster>`
7. Verify
   - `make verify CLUSTER=<cluster>`

## AWS runbook

### Account and credentials

- Create an IAM user (not root) with `AdministratorAccess` for MVP.
- Create an access key and configure the local profile:
  - `aws configure --profile signet`
- Verify the guardrail account:
  - `aws sts get-caller-identity --profile signet`
  - Must match `platform.account_id` in `cluster.yaml`.

### DNS delegation

- `make tf-apply` will create or reuse a Route53 hosted zone for `dns.base_domain`.
- If the hosted zone is created here, delegate the subdomain from the parent zone:
  - Copy the NS records for `dns.base_domain` into the parent zone (for example,
    delegate `aws.ocp.signet.ing` from `signet.ing`).

### Provisioning commands (AWS)

```bash
export CLUSTER=throwaway
make preflight        CLUSTER=$CLUSTER
make tf-bootstrap     CLUSTER=$CLUSTER
make tf-apply         CLUSTER=$CLUSTER
make cluster-create   CLUSTER=$CLUSTER
make bootstrap-gitops CLUSTER=$CLUSTER
make verify           CLUSTER=$CLUSTER
```

### Teardown

- `make cluster-destroy CLUSTER=<cluster>`
- Note: DNS/IAM prereqs are separate. Clean them up only if you intend to remove
  the cluster's cloud scaffolding.

### Manual STS (AWS)

- See `docs/CCO_MANUAL_STS.md` for the current prototype workflow.

## Azure runbook (placeholder)

Not yet implemented. Expect to provide:

- Subscription ID and tenant ID
- Service principal credentials
- DNS zone details for delegated subdomain

## GCP runbook (placeholder)

Not yet implemented. Expect to provide:

- Project ID
- Service account credentials
- Cloud DNS zone details for delegated subdomain

## Troubleshooting

See `docs/TROUBLESHOOTING.md` for failure modes and recovery steps.

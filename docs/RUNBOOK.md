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
4. Check EC2 quotas (AWS)
   - `make quotas CLUSTER=<cluster>`
   - Optional (repo-wide scan): `make quotas-all`
5. Provision cloud prereqs
   - `make tf-bootstrap CLUSTER=<cluster>` (one-time per cloud account)
   - `make tf-apply CLUSTER=<cluster>` (per cluster)
6. Delegate DNS (if needed)
   - If `tf-apply` created a new public DNS zone for `dns.base_domain`, delegate it from the parent DNS zone by creating an NS record set that points at the child zone's name servers.
   - Wait for propagation and confirm `dig NS <dns.base_domain>` returns the expected name servers.
7. Create the cluster
   - `make cluster-create CLUSTER=<cluster>`
8. Handoff to GitOps
   - `make bootstrap-gitops CLUSTER=<cluster>`
9. Verify
   - `make verify CLUSTER=<cluster>`

## AWS runbook

### Account and credentials

- Create an IAM user (not root) with `AdministratorAccess` for MVP.
- In the AWS console (root login), go to IAM → Users → Create user → Attach policies → AdministratorAccess → create access key.
- Configure the local profile:
  - `aws configure --profile signet`
- Verify the guardrail account:
  - `aws sts get-caller-identity --profile signet`
  - Must match `platform.account_id` in `cluster.yaml`.

### DNS delegation

- `make tf-apply` will create or reuse a Route53 hosted zone for `dns.base_domain`.
- If a new hosted zone is created, you **delegate it after `tf-apply` and before `cluster-create`**:
  1. Run `make tf-apply CLUSTER=<cluster>`.
  2. Read the name servers from `clusters/<cluster>/.work/terraform-prereqs.json`:

     ```bash
     jq -r '.name_servers.value[]' "clusters/<cluster>/.work/terraform-prereqs.json"
     ```

  3. In the *parent* DNS zone (wherever `signet.ing` or `ocp.signet.ing` is hosted),
     create an NS record set for `dns.base_domain` that contains those name servers.
  4. Confirm delegation before starting the installer:

     ```bash
     dig NS "<dns.base_domain>" +short
     ```

Why this is required: creating a hosted zone in Route53 does not automatically make it
reachable from the public internet. Delegation is the step that tells resolvers to send
queries for that subdomain to the new zone's name servers.

### Spot workers (AWS)

OpenShift control plane instances should remain On-Demand. Worker capacity can be Spot.

To use Spot workers:

- Set `compute_market: spot` under `openshift:` in `clusters/<cluster>/cluster.yaml`.
- Keep `openshift.compute_replicas` as the desired number of workers.
- Install the cluster, then convert/scale workers:
  - `make spot-workers CLUSTER=<cluster>`

This patches worker MachineSets so that new Machines are Spot. Existing worker Machines
are not automatically replaced.

### Provisioning commands (AWS)

```bash
export CLUSTER=throwaway
make preflight        CLUSTER=$CLUSTER
make quotas           CLUSTER=$CLUSTER
make tf-bootstrap     CLUSTER=$CLUSTER
make tf-apply         CLUSTER=$CLUSTER
make cluster-create   CLUSTER=$CLUSTER
make spot-workers     CLUSTER=$CLUSTER   # if compute_market under openshift is spot
make bootstrap-gitops CLUSTER=$CLUSTER
make verify           CLUSTER=$CLUSTER
```

### Teardown

- `make cluster-destroy CLUSTER=<cluster>`
- Note: DNS/IAM prereqs are separate. Clean them up only if you intend to remove
  the cluster's cloud scaffolding.

#### Teardown sanity-check (AWS)

OpenShift/installer tags AWS resources with the installer `infraID` (not the cluster name).
If you want to confirm what will be deleted (or verify cleanup after destroy):

```bash
export CLUSTER=<cluster>
infra=$(jq -r .infraID "clusters/${CLUSTER}/.work/installer/metadata.json")

# Ensure you're querying the correct AWS account/profile.
AWS_PROFILE=<profile> aws sts get-caller-identity --query Account --output text

# List cluster-owned EC2 instances (masters + workers, Spot or On-Demand).
AWS_PROFILE=<profile> aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned" \
           "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value]' \
  --output table
```

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

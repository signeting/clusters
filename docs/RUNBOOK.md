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
   - Optional (repo-wide scan, includes limits): `make quotas-all`
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

## Access and URLs

Kubeconfig and admin password (gitignored outputs):

- `clusters/<cluster>/.work/kubeconfig` (this repo's normalized output)
- `clusters/<cluster>/.work/installer/auth/kubeconfig` (installer output)
- `clusters/<cluster>/.work/installer/auth/kubeadmin-password`

Dashboard URLs (OpenShift defaults):

- Apps base domain: `apps.<cluster>.<dns.base_domain>`
- OpenShift Console: `https://console-openshift-console.apps.<cluster>.<dns.base_domain>`
- Argo CD (OpenShift GitOps): `https://openshift-gitops-server-openshift-gitops.apps.<cluster>.<dns.base_domain>`
- OAuth: `https://oauth-openshift.apps.<cluster>.<dns.base_domain>`
- Prometheus: `https://prometheus-k8s-openshift-monitoring.apps.<cluster>.<dns.base_domain>`
- Alertmanager: `https://alertmanager-main-openshift-monitoring.apps.<cluster>.<dns.base_domain>`
- Grafana: `https://grafana-openshift-monitoring.apps.<cluster>.<dns.base_domain>`
- Thanos Query: `https://thanos-querier-openshift-monitoring.apps.<cluster>.<dns.base_domain>`
- API server: `https://api.<cluster>.<dns.base_domain>:6443`

Prod cluster links (current):

- OpenShift Console: `https://console-openshift-console.apps.prod.aws.ocp.signet.ing`
- Argo CD (OpenShift GitOps): `https://openshift-gitops-server-openshift-gitops.apps.prod.aws.ocp.signet.ing`
- OAuth: `https://oauth-openshift.apps.prod.aws.ocp.signet.ing`
- Prometheus: `https://prometheus-k8s-openshift-monitoring.apps.prod.aws.ocp.signet.ing`
- Alertmanager: `https://alertmanager-main-openshift-monitoring.apps.prod.aws.ocp.signet.ing`
- Grafana: `https://grafana-openshift-monitoring.apps.prod.aws.ocp.signet.ing`
- Thanos Query: `https://thanos-querier-openshift-monitoring.apps.prod.aws.ocp.signet.ing`
- API server: `https://api.prod.aws.ocp.signet.ing:6443`

If a route does not resolve yet, list the actual routes:

```bash
KUBECONFIG=clusters/<cluster>/.work/kubeconfig oc get route -A
```

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

### Node pools and MachineSets (AWS)

- Baseline worker MachineSets are created by the installer; this repo may patch them for Spot via `make spot-workers`.
- Additional/specialized pools (GPU, infra, storage) and their scheduling policy (labels/taints) should be managed in `bitiq-io/gitops` so Argo CD can reconcile drift.
- MachineSets are cluster-specific (they embed the installer `infraID`); template/inject `infraID` during GitOps bootstrap and be cautious with Argo CD prune on capacity resources.
- Before applying GitOps changes that add/scale new instance families (especially GPU), run `make quotas CLUSTER=<cluster>` to confirm EC2 quota headroom.

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

# Runbook

This runbook is cloud-agnostic. Provider-specific details live in their sections.
Scope: Day-0 provisioning and Day-1 GitOps handoff only.

## Inputs and outputs (all clouds)

- Source of truth: `clusters/<cluster>/cluster.yaml`
- Secrets (gitignored): `secrets/<cluster>/pull-secret.json`, `secrets/<cluster>/ssh.pub`
- Generated outputs (gitignored): `clusters/<cluster>/.work/`

## Common workflow (all clouds)

1. Create a cluster definition
   - Copy the provider example under `clusters/_example/` (AWS: use `aws-multi-az` for prod, `aws-single-az` for cheap throwaway/dev).
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
8. Configure external Vault auth (only if using external Vault)
   - Required for VCO/VSO to authenticate on fresh clusters.
   - `VAULT_ADDR=https://vault.bitiq.io:8200 VAULT_TOKEN=... make vault-k8s-auth CLUSTER=<cluster>`
   - Note: Vault Kubernetes auth config is cluster-specific. If you have multiple clusters simultaneously, use separate auth mounts per cluster/env and ensure the GitOps repo is configured to use the matching mount.
9. Handoff to GitOps
   - `make bootstrap-gitops CLUSTER=<cluster>`
   - Canonical workflow: run bootstrap from this repo via `make bootstrap-gitops` / `scripts/bootstrap-gitops.sh` (even if you are actively developing in `bitiq-io/gitops`).
   - Reason: it derives `ENV`/`BASE_DOMAIN` from `clusters/<cluster>/cluster.yaml`, configures Vault Kubernetes auth (when `VAULT_ADDR`/`VAULT_TOKEN` are set), sets up Argo repo credentials, and writes a trace file under `clusters/<cluster>/.work/`.
   - Running `bitiq-io/gitops/scripts/bootstrap.sh` directly is supported for debugging, but it is not the canonical path.
10. Verify
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
- RHOAI (OpenShift AI): `https://data-science-gateway.apps.prod.aws.ocp.signet.ing`
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
- GPU capacity note: AWS GPU instance capacity can be AZ-specific. If you’re intentionally running single-AZ for cost but need GPUs elsewhere, keep baseline pools in one AZ and add GPU-only private subnets/MachineSets in additional AZs (GitOps-managed), at the cost of cross-AZ traffic (NAT/control-plane/service chatter).

### Provisioning commands (AWS)

If the GitOps repo is private, export repo creds before bootstrap:

```bash
export GITOPS_REPO_USERNAME=<github-username>
export GITOPS_REPO_PASSWORD=<github-pat>
```

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
  - Prompts you to type the cluster name
  - Verifies `dns.hosted_zone_id` still exists (and is preserved)
  - Runs an AWS cleanup report (including cross-AZ GPU workers/subnets)
- Optional: `make cleanup-check CLUSTER=<cluster>` (re-run the AWS cleanup report)
- Optional: `make tf-destroy CLUSTER=<cluster>` (destroy Terraform DNS/IAM prereqs)
  - Preserves the Route53 hosted zone by default
  - Skip this if you plan to recreate soon (it deletes IAM prereqs like the provisioner role)
  - Set `DESTROY_HOSTED_ZONE=1` if you explicitly want Terraform to delete a zone it created

#### Teardown sanity-check (AWS)

OpenShift/installer tags AWS resources with the installer `infraID` (not the cluster name).
If you want to confirm what will be deleted (or verify cleanup after destroy):

```bash
export CLUSTER=<cluster>
make cleanup-check CLUSTER=$CLUSTER

# Or do it manually:
infra=$(jq -r .infraID "clusters/${CLUSTER}/.work/installer/metadata.json")

# Ensure you're querying the correct AWS account/profile.
AWS_PROFILE=<profile> aws sts get-caller-identity --query Account --output text

# List cluster-owned EC2 instances (masters + workers, Spot or On-Demand).
AWS_PROFILE=<profile> aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:kubernetes.io/cluster/${infra},Values=owned,shared" \
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

## Installer Version Policy (Guardrails)

This repo treats `clusters/<cluster>/cluster.yaml: openshift.version` as the desired OpenShift version:

- `X.Y` (track the latest patch in that minor), or
- `X.Y.Z` (pin an exact patch)

Preflight enforces that **the local `openshift-install` binary matches the latest patch release** for the chosen minor.
This is required because `install-config.yaml` does not pin a release image; `cluster-create` installs whatever
`openshift-install` is on your `PATH`.

To avoid accidentally bumping to a newer OpenShift minor (e.g. adopting `4.21` before your operators are ready),
set `openshift.max_minor: "X.Y"` in `cluster.yaml`. Preflight will fail if `openshift.version` exceeds `max_minor`.

Why: `cluster-create` installs whatever `openshift-install` is on your `PATH`. If your local installer is old,
you will silently install an older OpenShift, even if `cluster.yaml` says otherwise.

### Download the latest `openshift-install` (and `oc`)

Official client mirror:
- `https://mirror.openshift.com/pub/openshift-v4/clients/ocp/`

Pick the newest `X.Y.Z/` directory, then download the installer + client tarballs for your OS:

macOS (Intel/Apple Silicon):
```bash
export OCP_VERSION=<X.Y.Z>
curl -fsSL -o /tmp/openshift-install.tgz "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-mac.tar.gz"
curl -fsSL -o /tmp/openshift-client.tgz  "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-mac.tar.gz"
tar -C /tmp -xzf /tmp/openshift-install.tgz openshift-install
tar -C /tmp -xzf /tmp/openshift-client.tgz oc kubectl
sudo install -m 0755 /tmp/openshift-install /usr/local/bin/openshift-install
sudo install -m 0755 /tmp/oc /usr/local/bin/oc
```

Linux:
```bash
export OCP_VERSION=<X.Y.Z>
curl -fsSL -o /tmp/openshift-install.tgz "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz"
curl -fsSL -o /tmp/openshift-client.tgz  "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz"
tar -C /tmp -xzf /tmp/openshift-install.tgz openshift-install
tar -C /tmp -xzf /tmp/openshift-client.tgz oc kubectl
sudo install -m 0755 /tmp/openshift-install /usr/local/bin/openshift-install
sudo install -m 0755 /tmp/oc /usr/local/bin/oc
```

Verify:
```bash
openshift-install version
oc version --client
```

# Troubleshooting

## Quick checks

- `make preflight CLUSTER=<cluster>` should pass before any cloud writes.
- Cloud identity must match `platform.account_id` (AWS: `aws sts get-caller-identity`).
- `oc get nodes` and `oc get co` should converge after install.

## Common failure modes

### Wrong cloud account/profile (AWS)

Symptoms: `preflight` fails with an account mismatch.

Fix:
- Set `AWS_PROFILE` to the correct profile or update `credentials.aws_profile`.
- Re-run `make preflight`.

### Missing secrets (all clouds)

Symptoms: `preflight` fails on `pull-secret.json` or `ssh.pub`.

Fix:
- Place `secrets/<cluster>/pull-secret.json` and `secrets/<cluster>/ssh.pub`.
- Re-run `make preflight`.

### Terraform state backend missing (AWS)

Symptoms: `make tf-apply` fails to init the backend.

Fix:
- Run `make tf-bootstrap CLUSTER=<cluster>`.
- Ensure the bucket exists in the correct account/region.

### AWS On-Demand vCPU quota too low

Symptoms: `cluster-create` fails with an error like:
`error(MissingQuota): ec2/L-1216C47A ... required ... is more than the limit ...`

Fix (pick one):
- Reduce `openshift.*_replicas` and/or instance types so required On-Demand vCPUs fit the quota.
- Use Spot for workers:
  - Set `compute_market: spot` under `openshift:`
  - Re-run `make cluster-create`
  - Then run `make spot-workers CLUSTER=<cluster>`
- Request a higher On-Demand vCPU quota for the region (`ec2/L-1216C47A`).

### DNS delegation not ready (all clouds)

Symptoms: cluster install stalls on DNS or console routes do not resolve.

Fix:
- If this repo created the hosted zone, delegate NS records from the parent zone.
- Ensure the parent zone delegates the per-cloud subdomain (for example `aws.ocp.signet.ing`).
- Allow time for propagation.

### Installer failures (all clouds)

Symptoms: `openshift-install` exits with errors or stalls.

Fix:
- Inspect logs in `clusters/<cluster>/.work/installer/.openshift_install.log`.
- Run `make cluster-destroy`, fix the cause, and retry.

### GitOps bootstrap failures (all clouds)

Symptoms: `make bootstrap-gitops` fails or Argo resources do not appear.

Fix:
- Ensure `KUBECONFIG=clusters/<cluster>/.work/kubeconfig` works.
- Confirm `helm` is installed.
- If you see `no matches for kind "ArgoCD" in version "argoproj.io/v1beta1"`, the GitOps operator CRDs were not installed yet (fresh cluster race). Update to a version of this repo that includes `scripts/bootstrap-gitops.sh` ArgoCD CRD preflight, then re-run `make bootstrap-gitops`.
- Run bootstrap directly from `.work/gitops-src/`:
  `ENV=prod BASE_DOMAIN=apps.<cluster>.<base_domain> ./scripts/bootstrap.sh`

## Logs and artifacts

- `clusters/<cluster>/.work/installer/.openshift_install.log`
- `clusters/<cluster>/.work/terraform-prereqs.json`
- `clusters/<cluster>/.work/kubeconfig`
- `clusters/<cluster>/.work/gitops-bootstrap.json`

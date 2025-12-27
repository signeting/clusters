# Troubleshooting

## Quick checks

- `make preflight CLUSTER=<cluster>` should pass before any cloud writes.
- `aws sts get-caller-identity` must match `platform.account_id`.
- `oc get nodes` and `oc get co` should converge after install.

## Common failure modes

### Wrong AWS account

Symptoms: `preflight` fails with an account mismatch.

Fix:
- Set `AWS_PROFILE` to the correct profile or update `credentials.aws_profile`.
- Re-run `make preflight`.

### Missing secrets

Symptoms: `preflight` fails on `pull-secret.json` or `ssh.pub`.

Fix:
- Place `secrets/<cluster>/pull-secret.json` and `secrets/<cluster>/ssh.pub`.
- Re-run `make preflight`.

### Terraform state bucket missing

Symptoms: `make tf-apply` fails to init the backend.

Fix:
- Run `make tf-bootstrap CLUSTER=<cluster>`.
- Ensure the bucket exists in the correct account/region.

### DNS delegation not ready

Symptoms: cluster install stalls on DNS or console routes do not resolve.

Fix:
- If this repo created the hosted zone, delegate NS records from the parent zone.
- Allow time for propagation.

### Installer failures

Symptoms: `openshift-install` exits with errors or stalls.

Fix:
- Inspect logs in `clusters/<cluster>/.work/installer/.openshift_install.log`.
- Run `make cluster-destroy`, fix the cause, and retry.

### GitOps bootstrap failures

Symptoms: `make bootstrap-gitops` fails or Argo resources do not appear.

Fix:
- Ensure `KUBECONFIG=clusters/<cluster>/.work/kubeconfig` works.
- Confirm `helm` is installed.
- Run bootstrap directly from `.work/gitops-src/`:
  `ENV=prod BASE_DOMAIN=apps.<cluster>.<base_domain> ./scripts/bootstrap.sh`

## Logs and artifacts

- `clusters/<cluster>/.work/installer/.openshift_install.log`
- `clusters/<cluster>/.work/terraform-prereqs.json`
- `clusters/<cluster>/.work/kubeconfig`
- `clusters/<cluster>/.work/gitops-bootstrap.json`

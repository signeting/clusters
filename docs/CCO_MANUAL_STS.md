# CCO Manual STS (AWS)

Status: design + prototype script. This repo documents the flow and provides `scripts/cco-manual-sts.sh`, but it is not yet validated on a real cluster.

## Why manual STS

Manual STS avoids long-lived cloud credentials inside the cluster. IAM roles are created up front, and the Cloud Credential Operator consumes pre-created Secrets.

## Required AWS resources

- IAM OpenID Connect provider (OIDC) for the cluster.
- IAM roles + policies for each component credential request.
- Optional: private S3 bucket + CloudFront OIDC endpoint (`--create-private-s3-bucket`).

## Tooling

- `oc`, `openshift-install`, `aws`, `ccoctl`, `jq`, `yq`
- `ccoctl` is distributed with OpenShift releases. See upstream docs for extraction.
- `oc adm release extract` needs registry auth. By default the script uses `secrets/<cluster>/pull-secret.json`
  or `REGISTRY_AUTH_FILE` if set.

Upstream reference: `ccoctl` AWS commands in `cloud-credential-operator`:
https://raw.githubusercontent.com/openshift/cloud-credential-operator/master/docs/ccoctl.md

## High-level flow

1. Set `credentials.cco_mode: manual-sts` in `clusters/<cluster>/cluster.yaml`.
2. Render install-config with `credentialsMode: Manual`.
3. Run `openshift-install create manifests` to create `manifests/` and `metadata.json`.
4. Extract CredentialsRequests from the OpenShift release image.
5. Run `ccoctl aws create-all` to create OIDC + IAM resources.
6. Copy generated Secret manifests into the installer `manifests/` dir.
7. Run `openshift-install create cluster`.

## Prototype script

Use the helper script to run the steps safely:

```bash
export CLUSTER=<cluster>
export OPENSHIFT_RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:<version>-x86_64
scripts/cco-manual-sts.sh $CLUSTER
```

Optional env flags:

- `CCO_DRY_RUN=1` to generate AWS CLI JSON instead of creating resources.
- `CCO_CREATE_PRIVATE_S3_BUCKET=1` to create a private OIDC bucket/CloudFront endpoint.
- `ALLOW_INSTALLER_REUSE=1` to reuse a non-empty installer dir.
- `REGISTRY_AUTH_FILE=/path/to/pull-secret.json` to override the registry auth file.

Outputs:

- `clusters/<cluster>/.work/credrequests/` contains extracted CredentialsRequests.
- `clusters/<cluster>/.work/ccoctl/manifests/` contains Secret manifests for the installer.

Notes:

- The script honors `credentials.aws_profile` from `cluster.yaml` when running `ccoctl`.

## Manual commands (reference)

```bash
# Extract credentials requests from the release image
oc adm release extract --credentials-requests --cloud=aws \
  --to=./credrequests "${OPENSHIFT_RELEASE_IMAGE}"

# Create IAM + OIDC resources (from ccoctl docs)
ccoctl aws create-all --name=<infra-id> --region=<region> \
  --credentials-requests-dir=./credrequests \
  --output-dir=./ccoctl-output \
  --create-private-s3-bucket
```

Copy the resulting Secret manifests into the installer dir before creating the cluster:

```bash
cp -a ./ccoctl-output/manifests/. clusters/<cluster>/.work/installer/manifests/
```

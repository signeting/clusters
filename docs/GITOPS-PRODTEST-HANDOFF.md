# GitOps + Vault Multi-Cluster Handoff (`prodtest`)

Audience: a Codex agent working in `github.com/bitiq-io/gitops` (and the operator setting up Vault) who needs a concrete, repeatable path to “cluster recreate → GitOps bootstrap → green” without manual secret copying.

Last updated: 2026-02-03

---

## 1) Decisions (what we are doing and why)

- We will run **multiple clusters simultaneously** (at least one “local/CRC-ish” cluster and one AWS cluster).
- We want to avoid cloud-vendor lock-in, so the secrets source of truth is an **external Vault-compatible endpoint** (not a cloud-native secrets manager).
- We will reserve `ENV=prod` for “real production” later and use **`ENV=prodtest`** for **ephemeral prod workflow testing** (fast iteration, safe separation).

Why this matters:

- Vault’s Kubernetes auth config is **one cluster per auth mount** (a single `auth/kubernetes/config` can’t serve multiple clusters concurrently). Using a distinct mount per cluster avoids breaking one cluster when another is configured.
- A dedicated `prodtest` env overlay prevents “testing creds/config” from silently becoming “real prod defaults”.

---

## 2) Contract alignment (clusters repo ↔ gitops repo)

### 2.1 `signeting/clusters` (this repo)

- `clusters/<cluster>/cluster.yaml: gitops.env` selects which overlay is used in the GitOps repo.
- This repo now supports: `gitops.env: local|sno|prod|prodtest` (schema-enforced).

### 2.2 `bitiq-io/gitops`

To use `ENV=prodtest`, the GitOps repo must:

- accept `ENV=prodtest` in `scripts/bootstrap.sh` (if it validates `ENV`)
- provide an env overlay that configures:
  - destination namespace(s)
  - Vault runtime/config settings
  - operator/app enablement flags appropriate for prod-like testing

---

## 3) Multi-cluster Vault Kubernetes auth design (required)

### 3.1 Naming convention (recommended)

Create one Kubernetes auth mount per cluster class (or per cluster, if desired):

- `auth/kubernetes-local` → local/CRC cluster
- `auth/kubernetes-prodtest` → ephemeral AWS “prod test” cluster
- (later) `auth/kubernetes-prod` → real prod cluster

In GitOps values, match these mount paths:

- VCO: `vaultConfigMountPath: kubernetes-prodtest`
- VSO: `vaultRuntimeKubernetesMount: kubernetes-prodtest`

### 3.2 Bootstrap role requirement (`kube-auth`)

The GitOps repo uses a “bootstrap/controller” role (commonly named `kube-auth`) so VCO can authenticate to Vault and create per-env roles/policies.

Therefore:

- The `kube-auth` **policy** must exist in Vault (once).
- A `kube-auth` **role** must exist in **each auth mount** that a cluster will use (e.g., in `kubernetes-prodtest`), bound to the ServiceAccount that VCO uses (often `default` in `openshift-gitops`, unless overridden in values).

If the `kube-auth` role is missing for the mount, VCO cannot start (chicken-and-egg).

---

## 4) Per-cluster Vault auth configuration steps (prodtest example)

Run these from a machine with `oc` access to the target cluster.

### 4.1 Create a reviewer ServiceAccount (required)

Vault needs a token reviewer JWT that can perform TokenReviews. Create a dedicated SA and bind `system:auth-delegator`:

```bash
oc -n openshift-gitops create sa vault-token-reviewer || true
oc adm policy add-cluster-role-to-user system:auth-delegator \
  system:serviceaccount:openshift-gitops:vault-token-reviewer
```

### 4.2 Gather cluster identity inputs

```bash
KUBE_HOST="$(oc whoami --show-server)"
REVIEWER_JWT="$(oc -n openshift-gitops create token vault-token-reviewer --duration=24h)"
KUBE_CA="$(oc -n openshift-gitops get configmap kube-root-ca.crt -o jsonpath='{.data.ca\\.crt}')"
```

### 4.3 Write Vault auth mount config for this cluster

```bash
export VAULT_ADDR="https://vault.bitiq.io:8200"
export VAULT_TOKEN="<admin token>"   # do not use root token for day-to-day

vault write auth/kubernetes-prodtest/config \
  token_reviewer_jwt="$REVIEWER_JWT" \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA"
```

Notes:

- Tokens minted via `oc create token` are time-bound; decide whether to periodically refresh/rotate this config.
- If clusters will be long-lived, prefer an explicit reviewer-token rotation story (automation or runbook).

---

## 5) Required GitOps repo changes for `ENV=prodtest` (high-level)

In `bitiq-io/gitops`:

1. Add an env overlay `prodtest` (namespace `bitiq-prodtest` recommended).
2. Ensure prodtest points at the external Vault:
   - `vaultRuntimeAddress: https://vault.bitiq.io:8200`
   - `vaultConfigAddress: https://vault.bitiq.io:8200`
   - `vaultServerEnabled: false`
   - `vaultRuntimeKubernetesMount: kubernetes-prodtest`
   - `vaultConfigMountPath: kubernetes-prodtest`
   - `vaultConfigConnectionRole: kube-auth`
   - `vaultRuntimeRoleName`, `vaultConfigRoleName`, `vaultConfigPolicyName` should be `gitops-prodtest` (or equivalent) to keep test env isolated.
3. Keep/enable the secrets readiness check so failures are actionable and bounded (names-only, no secret data).

---

## 6) Clusters repo usage (once GitOps overlay exists)

In `clusters/<cluster>/cluster.yaml`, set:

- `gitops.env: prodtest`

Then bootstrap as normal:

```bash
export CLUSTER=prod
export GITOPS_REPO_USERNAME=<github-username>
export GITOPS_REPO_PASSWORD=<github-pat>
make bootstrap-gitops CLUSTER=$CLUSTER
```

---

## 7) Validation checklist (names-only)

After bootstrap:

- Argo/GitOps core:
  - `oc -n openshift-gitops get argocd openshift-gitops`
  - `oc -n openshift-gitops get applicationsets,applications`
- Vault apps:
  - `oc -n openshift-gitops get application vault-config-prodtest vault-runtime-prodtest`
- Secrets present (names only; do not print `.data`):
  - `oc -n openshift-gitops get secret argocd-image-updater-secret`
  - `oc -n openshift-pipelines get secret quay-auth github-webhook-secret gitops-repo-creds`
  - `oc -n bitiq-prodtest get secret toy-service-config toy-web-config` (or the prodtest equivalents)

If repo access fails, `signeting/clusters/scripts/bootstrap-gitops.sh` will now fail only on a detectable Argo repo access error (not just missing env vars).


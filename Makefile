SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help preflight validate quotas quotas-all tf-bootstrap tf-apply tf-destroy cco-manual-sts cluster-create cluster-destroy cleanup-check vault-k8s-auth bootstrap-gitops spot-workers verify

help:
	@printf "Usage: make <target> CLUSTER=<name>\n\n"
	@printf "Targets:\n"
	@printf "  preflight        Verify tools, schema, account, secrets\n"
	@printf "  validate         Validate cluster.yaml against the schema\n"
	@printf "  quotas           Check AWS EC2 vCPU quotas/usage (single cluster)\n"
	@printf "  quotas-all       Check AWS EC2 vCPU quotas/usage (all clusters, incl. limits)\n"
	@printf "  tf-bootstrap     One-time Terraform backend bootstrap\n"
	@printf "  tf-apply         Per-cluster Terraform prereqs (DNS/IAM)\n"
	@printf "  tf-destroy       Destroy per-cluster Terraform prereqs (preserves hosted zone by default)\n"
	@printf "  cco-manual-sts   Prepare AWS STS IAM/OIDC resources (manual CCO)\n"
	@printf "  cluster-create   Create cluster via openshift-install\n"
	@printf "  cluster-destroy  Destroy cluster via openshift-install\n"
	@printf "  cleanup-check    Report remaining AWS resources tagged to the cluster\n"
	@printf "  vault-k8s-auth   Configure external Vault Kubernetes auth for the cluster\n"
	@printf "  bootstrap-gitops Run GitOps bootstrap on the cluster\n"
	@printf "  spot-workers     Convert/scale worker MachineSets to Spot (AWS)\n"
	@printf "  verify           Verify cluster and GitOps health\n"
	@printf "\nEnvironment:\n"
	@printf "  CLUSTER          Cluster name (matches clusters/<cluster>)\n"

preflight:
	scripts/preflight.sh

validate:
	scripts/validate.sh

quotas:
	scripts/aws-quotas.sh

quotas-all:
	scripts/aws-quotas.sh --all --show-limits

tf-bootstrap:
	scripts/tf-bootstrap.sh

tf-apply:
	scripts/tf-apply.sh

tf-destroy:
	scripts/tf-destroy.sh

cco-manual-sts:
	scripts/cco-manual-sts.sh

cluster-create:
	scripts/cluster-create.sh

cluster-destroy:
	scripts/cluster-destroy.sh

cleanup-check:
	scripts/aws-cleanup-check.sh

vault-k8s-auth:
	scripts/vault-k8s-auth-config.sh

bootstrap-gitops:
	scripts/bootstrap-gitops.sh

spot-workers:
	scripts/spot-workers.sh

verify:
	scripts/verify.sh

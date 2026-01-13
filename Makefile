SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help preflight validate quotas quotas-all tf-bootstrap tf-apply cco-manual-sts cluster-create cluster-destroy bootstrap-gitops spot-workers verify

help:
	@printf "Usage: make <target> CLUSTER=<name>\n\n"
	@printf "Targets:\n"
	@printf "  preflight        Verify tools, schema, account, secrets\n"
	@printf "  validate         Validate cluster.yaml against the schema\n"
	@printf "  quotas           Check AWS EC2 vCPU quotas/usage (single cluster)\n"
	@printf "  quotas-all       Check AWS EC2 vCPU quotas/usage (all clusters)\n"
	@printf "  tf-bootstrap     One-time Terraform backend bootstrap\n"
	@printf "  tf-apply         Per-cluster Terraform prereqs (DNS/IAM)\n"
	@printf "  cco-manual-sts   Prepare AWS STS IAM/OIDC resources (manual CCO)\n"
	@printf "  cluster-create   Create cluster via openshift-install\n"
	@printf "  cluster-destroy  Destroy cluster via openshift-install\n"
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
	scripts/aws-quotas.sh --all

tf-bootstrap:
	scripts/tf-bootstrap.sh

tf-apply:
	scripts/tf-apply.sh

cco-manual-sts:
	scripts/cco-manual-sts.sh

cluster-create:
	scripts/cluster-create.sh

cluster-destroy:
	scripts/cluster-destroy.sh

bootstrap-gitops:
	scripts/bootstrap-gitops.sh

spot-workers:
	scripts/spot-workers.sh

verify:
	scripts/verify.sh

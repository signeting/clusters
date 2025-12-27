SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help preflight validate tf-bootstrap tf-apply cluster-create cluster-destroy bootstrap-gitops verify

help:
	@printf "Usage: make <target> CLUSTER=<name>\n\n"
	@printf "Targets:\n"
	@printf "  preflight        Verify tools, schema, account, secrets\n"
	@printf "  validate         Validate cluster.yaml against the schema\n"
	@printf "  tf-bootstrap     One-time Terraform backend bootstrap\n"
	@printf "  tf-apply         Per-cluster Terraform prereqs (DNS/IAM)\n"
	@printf "  cluster-create   Create cluster via openshift-install\n"
	@printf "  cluster-destroy  Destroy cluster via openshift-install\n"
	@printf "  bootstrap-gitops Run GitOps bootstrap on the cluster\n"
	@printf "  verify           Verify cluster and GitOps health\n"
	@printf "\nEnvironment:\n"
	@printf "  CLUSTER          Cluster name (matches clusters/<cluster>)\n"

preflight:
	scripts/preflight.sh

validate:
	scripts/validate.sh

tf-bootstrap:
	scripts/tf-bootstrap.sh

tf-apply:
	scripts/tf-apply.sh

cluster-create:
	scripts/cluster-create.sh

cluster-destroy:
	scripts/cluster-destroy.sh

bootstrap-gitops:
	scripts/bootstrap-gitops.sh

verify:
	scripts/verify.sh

# ceph-tekton — top-level developer targets.
#
# Phase 1: `make dev-up` for a local kind+Tekton dev cluster.
# Future phases (helm/terraform/deploy) will add targets here.

.SHELLFLAGS := -eu -o pipefail -c
SHELL := bash

# ---- versions (bump in PRs after testing) ----
TEKTON_PIPELINES_VERSION ?= v1.6.0

# ---- dev cluster ----
KIND_CLUSTER_NAME ?= ceph-tekton-dev

# ---- container runtime detection ----
# Prefer docker, fall back to podman. Exported so hack/ scripts see the choice.
CONTAINER_RUNTIME := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
ifeq ($(CONTAINER_RUNTIME),)
  $(error No container runtime found. Install docker or podman.)
endif
ifneq (,$(findstring podman,$(CONTAINER_RUNTIME)))
  export KIND_EXPERIMENTAL_PROVIDER := podman
endif

export KIND_CLUSTER_NAME
export TEKTON_PIPELINES_VERSION

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z][a-zA-Z0-9_-]*:.*?## / { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ---- dev cluster lifecycle ----

.PHONY: dev-up
dev-up: ## Create local kind cluster + install Tekton Pipelines.
	@./hack/dev-up.sh

.PHONY: dev-down
dev-down: ## Tear down the local dev cluster.
	kind delete cluster --name $(KIND_CLUSTER_NAME)

.PHONY: dev-status
dev-status: ## Show cluster + Tekton install status.
	@kubectl --context kind-$(KIND_CLUSTER_NAME) get nodes
	@echo
	@kubectl --context kind-$(KIND_CLUSTER_NAME) -n tekton-pipelines get pods

.PHONY: dev-test
dev-test: ## Run the hello-world pipeline and stream its logs.
	@./hack/dev-test.sh

.PHONY: dev-chains-up
dev-chains-up: ## Install Tekton Chains + bootstrap cosign signing keys.
	@./hack/dev-chains-setup.sh

.PHONY: dev-vault-up
dev-vault-up: ## Install Vault (helm) + enable transit + k8s auth.
	@./hack/dev-vault-up.sh

.PHONY: dev-kyverno-up
dev-kyverno-up: ## Install Kyverno (helm) + apply ceph-image-signature ClusterPolicy.
	@./hack/dev-kyverno-up.sh

.PHONY: dev-zgw-up
dev-zgw-up: ## Apply the zgw-posix base + smoke-probe the in-cluster S3 endpoint.
	@./hack/dev-zgw-up.sh

# ---- validation (no cluster needed) ----

.PHONY: kustomize-validate
kustomize-validate: ## Render every kustomize overlay (no apply).
	@for o in kustomize/overlays/*/; do \
	  echo "=== $$o ==="; \
	  kubectl kustomize "$$o" > /dev/null && echo "OK"; \
	done

.PHONY: pipelines-validate
pipelines-validate: ## Server-side dry-run apply of pipeline manifests against the dev cluster.
	@# Issue #68 split multi-doc smoke pipelines into single-resource
	@# files under pipelines/{tasks,pipelines}/; setup bundles (non-Tekton
	@# RBAC/Namespace prereqs) live under manifests/smoke-setup/. Validate
	@# every layer + the legacy top-level files (build-grype-db, noop-pull-request).
	@for f in pipelines/*.yaml pipelines/tasks/*.yaml pipelines/pipelines/*.yaml manifests/smoke-setup/*.yaml; do \
	  [ -f "$$f" ] || continue; \
	  echo "=== $$f ==="; \
	  kubectl --context kind-$(KIND_CLUSTER_NAME) apply --dry-run=server -f "$$f"; \
	done

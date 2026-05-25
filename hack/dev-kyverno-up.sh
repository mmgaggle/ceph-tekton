#!/usr/bin/env bash
# Bootstrap Kyverno into the local kind dev cluster (created by
# `hack/dev-up.sh`) and apply the ceph-tekton ClusterPolicies that
# enforce cosign-signature verification on Ceph container images.
#
# What this script does (idempotent — safe to re-run):
#   1. Add/refresh the kyverno helm repo.
#   2. Install the kyverno chart with charts/kyverno/values-dev.yaml
#      into the `kyverno` namespace.
#   3. Wait for the admission, background, cleanup, and reports
#      controllers to become ready.
#   4. Apply the dev ClusterPolicy (verify-ceph-image-signatures-dev)
#      via the kustomize base. The Sepia-targeted policy in the same
#      base is gated by a cluster-name label match and will not enforce
#      on the kind dev cluster — see the policy's matchLabels selector.
#   5. Wait for the policies to report Ready.
#   6. Print next-step instructions for running the smoke-test
#      pipeline.
#
# Prereq: `hack/dev-chains-setup.sh` must have already run, because
# the dev ClusterPolicy reads the cosign public key from the
# `tekton-chains/signing-secrets` Secret that script creates. The
# script checks for the Secret and aborts with a clear message if
# it's missing.
#
# DO NOT use this script (or values-dev.yaml) on a shared or
# production cluster. Single-replica admission with failurePolicy=Ignore
# is a dev convenience, not a production stance.

set -euo pipefail

CLUSTER="${KIND_CLUSTER_NAME:-ceph-tekton-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- pins (bump in PRs after testing against the smoke-test pipeline) ----
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.3.7}"   # kyverno/kyverno chart, appVersion v1.13.4
KYVERNO_NAMESPACE="${KYVERNO_NAMESPACE:-kyverno}"
CHAINS_NAMESPACE="${CHAINS_NAMESPACE:-tekton-chains}"
CHAINS_SECRET="${CHAINS_SECRET:-signing-secrets}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    cat >&2 <<EOF
error: required tool '$1' not found on PATH.
       install: $2
EOF
    exit 1
  fi
}

require kubectl "brew install kubectl"
require helm    "brew install helm"

kubectl config use-context "kind-$CLUSTER" >/dev/null

# ---- 0. prereq: cosign public key must exist ----
# The dev ClusterPolicy references the cosign.pub key from the
# `signing-secrets` Secret that hack/dev-chains-setup.sh creates.
# Fail loud here instead of letting Kyverno load a policy with a
# dangling reference.
if ! kubectl -n "$CHAINS_NAMESPACE" get secret "$CHAINS_SECRET" \
     -o jsonpath='{.data.cosign\.pub}' 2>/dev/null | grep -q .; then
  cat >&2 <<EOF
error: $CHAINS_NAMESPACE/$CHAINS_SECRET has no cosign.pub field.
       The dev ClusterPolicy references that key. Run
       hack/dev-chains-setup.sh first, then re-run this script.
EOF
  exit 1
fi

# ---- 1. helm repo ----
if ! helm repo list -o json 2>/dev/null | grep -q '"name":"kyverno"'; then
  echo "adding kyverno helm repo..."
  helm repo add kyverno https://kyverno.github.io/kyverno/
fi
helm repo update kyverno >/dev/null

# ---- 2. install/upgrade the chart ----
echo "installing kyverno helm chart $KYVERNO_CHART_VERSION into namespace '$KYVERNO_NAMESPACE'..."
helm upgrade --install kyverno kyverno/kyverno \
  --namespace "$KYVERNO_NAMESPACE" --create-namespace \
  --version "$KYVERNO_CHART_VERSION" \
  --values "$REPO_ROOT/charts/kyverno/values-dev.yaml" \
  --wait --timeout 5m

# ---- 3. wait for the controllers ----
# Each Kyverno controller is its own Deployment with its own label.
# Wait on all four so the smoke test isn't racing against a
# half-initialised admission webhook.
echo "waiting for kyverno controllers to become ready..."
for component in admission-controller background-controller cleanup-controller reports-controller; do
  echo "  - $component"
  kubectl -n "$KYVERNO_NAMESPACE" wait --for=condition=ready pod \
    -l "app.kubernetes.io/component=$component" \
    --timeout=180s
done

# ---- 4. apply the ClusterPolicies ----
echo "applying kustomize/base/kyverno-policies/..."
kubectl apply -k "$REPO_ROOT/kustomize/base/kyverno-policies/"

# ---- 5. wait for the policies to report Ready ----
# Kyverno's policy controller sets .status.ready=true once the policy
# has been compiled and its webhook configuration synced. A policy
# with a bad attestor reference will sit at Ready=false here.
echo "waiting for ClusterPolicies to become ready..."
for policy in verify-ceph-image-signatures-dev verify-ceph-image-signatures-sepia; do
  echo "  - $policy"
  # `kubectl wait` against a custom .status field needs --for=jsonpath.
  kubectl wait --for=jsonpath='{.status.ready}'=true \
    "clusterpolicy/$policy" --timeout=60s || {
      echo "warn: ClusterPolicy $policy is not ready — inspect with:"
      echo "      kubectl describe clusterpolicy $policy"
    }
done

# ---- 6. next steps ----
cat <<EOF

kyverno is up in the dev cluster.
  chart:       kyverno/kyverno $KYVERNO_CHART_VERSION
  namespace:   $KYVERNO_NAMESPACE
  policies:    verify-ceph-image-signatures-dev    (enforces on kind dev)
               verify-ceph-image-signatures-sepia  (sepia-only, will not enforce here)

policy posture (dev):
  - Matches quay.io/ceph/* container images.
  - Verifies cosign signature with the public key in
    $CHAINS_NAMESPACE/$CHAINS_SECRET (cosign.pub).
  - Skips namespaces hosting the ceph-tekton stack itself
    (tekton-pipelines, tekton-chains, vault, pipelines-as-code, kyverno).

next:
  # run the smoke-test pipeline — one TaskRun pulls a signed image
  # (expects admission), one pulls an unsigned image (expects rejection).
  kubectl apply -f pipelines/kyverno-smoke-test.yaml
  tkn pipeline start kyverno-smoke-test --showlog

  # inspect a policy decision after the fact:
  kubectl get policyreport -A
  kubectl describe clusterpolicy verify-ceph-image-signatures-dev

teardown of just kyverno (leaves the kind cluster + tekton + chains in place):
  kubectl delete -k $REPO_ROOT/kustomize/base/kyverno-policies/
  helm -n $KYVERNO_NAMESPACE uninstall kyverno
  kubectl delete namespace $KYVERNO_NAMESPACE

EOF

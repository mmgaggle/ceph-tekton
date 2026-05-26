#!/usr/bin/env bash
# One-time Tekton Chains bootstrap for the local dev cluster:
#   1. Install Chains via the kustomize base
#   2. Generate a cosign x509 keypair and load it into the
#      `signing-secrets` Secret in the tekton-chains namespace
#   3. Restart the Chains controller so it picks up the keys
#
# Idempotent: rerun after `make dev-down && make dev-up` to rebootstrap.
# The Sepia overlay swaps cosign-key signing for Fulcio keyless and skips
# the key-generation step entirely.

set -euo pipefail

CLUSTER="${KIND_CLUSTER_NAME:-ceph-tekton-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
require cosign  "brew install cosign"

kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "applying kustomize/base/tekton-chains/..."
kubectl apply -k "$REPO_ROOT/kustomize/base/tekton-chains/"

echo "waiting for tekton-chains-controller pod..."
kubectl -n tekton-chains wait --for=condition=ready pod \
  -l app.kubernetes.io/part-of=tekton-chains \
  --timeout=300s || true

# cosign generate-key-pair k8s://... creates the Secret directly. Skip
# if it already has the cosign.key field.
if kubectl -n tekton-chains get secret signing-secrets \
     -o jsonpath='{.data.cosign\.key}' 2>/dev/null | grep -q .; then
  echo "signing-secrets already has cosign.key — skipping keypair generation"
else
  echo "generating cosign keypair into tekton-chains/signing-secrets..."
  # cosign prompts for a passphrase. For dev we use an empty passphrase
  # piped via stdin; production should use a strong passphrase from a
  # secret manager.
  COSIGN_PASSWORD="" cosign generate-key-pair "k8s://tekton-chains/signing-secrets"
fi

echo "restarting chains controller to pick up the new key..."
kubectl -n tekton-chains rollout restart deploy/tekton-chains-controller
kubectl -n tekton-chains rollout status  deploy/tekton-chains-controller --timeout=120s

cat <<EOF

Tekton Chains is configured.
  config:    ConfigMap tekton-chains/chains-config
  key:       Secret    tekton-chains/signing-secrets (cosign.key, cosign.pub)
  rekor:     https://rekor.sigstore.dev (public-good)

next:
  kubectl apply -f $REPO_ROOT/pipelines/tasks/chains-smoke-build.yaml
  kubectl apply -f $REPO_ROOT/pipelines/tasks/chains-smoke-sbom.yaml
  kubectl apply -f $REPO_ROOT/pipelines/pipelines/chains-smoke-test.yaml
  tkn pipeline start chains-smoke-test --showlog
  # then verify per docs/provenance.md

EOF

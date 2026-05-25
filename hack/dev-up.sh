#!/usr/bin/env bash
# Bootstrap a local kind cluster + Tekton Pipelines for ceph-tekton dev.
# Invoked by `make dev-up`. Idempotent: re-running on a live cluster only
# reconciles the Tekton install.

set -euo pipefail

CLUSTER="${KIND_CLUSTER_NAME:-ceph-tekton-dev}"
TEKTON_VERSION="${TEKTON_PIPELINES_VERSION:-v0.62.0}"
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

require kubectl   "brew install kubectl"
require kind      "brew install kind"
require tkn       "brew install tektoncd-cli"

if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
  CONTAINER_RUNTIME="$(command -v docker || command -v podman || true)"
fi
if [[ -z "$CONTAINER_RUNTIME" ]]; then
  echo "error: docker or podman required" >&2
  exit 1
fi
if [[ "$CONTAINER_RUNTIME" == *podman* ]]; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  # kind on podman needs the podman machine running (macOS)
  if ! podman machine list --format '{{.Running}}' 2>/dev/null | grep -q true; then
    echo "starting podman machine..."
    podman machine start || true
  fi
fi

# Create the cluster if it doesn't exist.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "kind cluster '$CLUSTER' already exists — skipping create"
else
  echo "creating kind cluster '$CLUSTER'..."
  kind create cluster --name "$CLUSTER" --config "$SCRIPT_DIR/kind-config.yaml"
fi

kubectl config use-context "kind-$CLUSTER" >/dev/null

# Render + apply the dev-local overlay (which pulls in Tekton release.yaml).
echo "applying Tekton Pipelines $TEKTON_VERSION via kustomize dev-local overlay..."
kubectl apply -k "$REPO_ROOT/kustomize/overlays/dev-local"

echo "waiting for tekton-pipelines controller to become ready..."
kubectl -n tekton-pipelines wait --for=condition=ready pod \
  -l app.kubernetes.io/part-of=tekton-pipelines \
  --timeout=300s

cat <<EOF

ceph-tekton dev cluster is up.
  cluster:   kind-$CLUSTER
  tekton:    $TEKTON_VERSION
  context:   kubectl config use-context kind-$CLUSTER

next:
  make dev-test       # run the hello-world pipeline
  make dev-status     # show cluster + tekton state
  make dev-down       # tear it all down

EOF

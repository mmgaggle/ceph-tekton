#!/usr/bin/env bash
# Apply the hello-world Pipeline and run it; stream logs until completion.
# Invoked by `make dev-test`.

set -euo pipefail

CLUSTER="${KIND_CLUSTER_NAME:-ceph-tekton-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "applying $REPO_ROOT/pipelines/hello-world.yaml..."
kubectl apply -f "$REPO_ROOT/pipelines/hello-world.yaml"

echo "starting hello-world pipeline..."
tkn pipeline start hello-world \
  --param who=ceph \
  --showlog

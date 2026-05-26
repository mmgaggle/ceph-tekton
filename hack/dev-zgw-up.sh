#!/usr/bin/env bash
# Bootstrap the in-cluster zgw-posix S3 endpoint on the local kind
# dev cluster (created by `hack/dev-up.sh`).
#
# What this script does (idempotent — safe to re-run):
#   1. Verify the kind cluster is reachable.
#   2. Apply kustomize/base/zgw-posix/ (also pulled in by the dev-local
#      overlay; the standalone script lets a contributor add zgw to an
#      already-running dev cluster without re-applying everything).
#   3. Wait for the zgw-posix Pod to become Ready.
#   4. Port-forward briefly and confirm the S3 surface is alive via
#      `aws s3api list-buckets` against the configured credentials.
#   5. Print the in-cluster Service URL plus the laptop-side
#      port-forward command a contributor would use to talk to it.
#
# Architectural shape: Sepia OpenShift co-locates real Ceph RGW with
# Tekton so Pipelines reach S3 without leaving the cluster network.
# This script gives the dev kind cluster the same shape — Pipelines
# resolve `http://zgw-posix.zgw-posix.svc.cluster.local` and hit a
# single-Pod zgw-posix that mirrors RGW's S3 wire format.
#
# DO NOT use this script on a shared or production cluster. zgw-posix
# is an experimental research backend; the credentials are literal
# in-tree defaults.

set -euo pipefail

CLUSTER="${KIND_CLUSTER_NAME:-ceph-tekton-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- knobs (match the contract in hack/verify-s3-module.sh) ----
ZGW_NAMESPACE="${ZGW_NAMESPACE:-zgw-posix}"
ZGW_ACCESS_KEY="${ZGW_ACCESS_KEY:-cephtekton}"
ZGW_SECRET_KEY="${ZGW_SECRET_KEY:-cephtekton}"
# Local laptop-side port used for the smoke check below. Picks 18080
# to avoid colliding with anything else a contributor commonly runs
# (Tekton dashboard is 9097, Vault UI 8200, kyverno admission 9443).
LOCAL_PORT="${LOCAL_PORT:-18080}"
SMOKE_REGION="${SMOKE_REGION:-default}"

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
require aws     "brew install awscli"

kubectl config use-context "kind-$CLUSTER" >/dev/null

# ---- 1. cluster reachable? ----
if ! kubectl version >/dev/null 2>&1; then
  echo "error: cannot reach the API server for context kind-$CLUSTER" >&2
  echo "       (is the kind cluster up? \`kind get clusters\`)" >&2
  exit 1
fi

# ---- 2. apply the base ----
echo "applying kustomize/base/zgw-posix/..."
kubectl apply -k "$REPO_ROOT/kustomize/base/zgw-posix/"

# ---- 3. wait for Ready ----
echo "waiting for zgw-posix pod to become ready..."
# The pod label-selector is `app=zgw-posix` (set in deployment.yaml).
# 120s covers the cold image-pull case for quay.io/dparkes/zgw-posix
# on a warm kind cache; on first-ever pull, bump LOCAL via the env.
kubectl -n "$ZGW_NAMESPACE" wait --for=condition=ready pod \
  -l app=zgw-posix --timeout="${ZGW_READY_TIMEOUT:-120s}"

# ---- 4. smoke-probe via port-forward ----
echo "smoke-probing the S3 surface via port-forward..."

# Start the port-forward in the background, capture PID so we can kill
# it on exit (or if the smoke check itself fails). Suppress its noisy
# default stdout — `kubectl port-forward` prints a line per binding
# that we don't need in the script's output.
PF_LOG="$(mktemp)"
trap 'rm -f "$PF_LOG"; if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; fi' EXIT

kubectl -n "$ZGW_NAMESPACE" port-forward svc/zgw-posix \
  "$LOCAL_PORT:80" >"$PF_LOG" 2>&1 &
PF_PID=$!

# Poll for the local socket to come up. kubectl port-forward prints
# `Forwarding from 127.0.0.1:NNNN -> 8000` once the listener is bound.
for i in $(seq 1 20); do
  if grep -q "Forwarding from" "$PF_LOG"; then
    break
  fi
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "error: kubectl port-forward died before it could bind" >&2
    cat "$PF_LOG" >&2
    exit 1
  fi
  sleep 0.5
  if (( i == 20 )); then
    echo "error: port-forward did not bind within ~10s" >&2
    cat "$PF_LOG" >&2
    exit 1
  fi
done

ENDPOINT="http://127.0.0.1:${LOCAL_PORT}"
echo "  endpoint: ${ENDPOINT}"

# aws s3api list-buckets against an empty zgw-posix returns an empty
# `Buckets:` array — the success criterion is that the HTTP+auth path
# resolves, not that there's content.
AWS_ARGS=(--endpoint-url "$ENDPOINT" --region "$SMOKE_REGION")
if AWS_ACCESS_KEY_ID="$ZGW_ACCESS_KEY" \
   AWS_SECRET_ACCESS_KEY="$ZGW_SECRET_KEY" \
   aws "${AWS_ARGS[@]}" s3api list-buckets >/dev/null 2>&1; then
  echo "  smoke OK — list-buckets returned cleanly"
else
  echo "error: aws s3api list-buckets failed against ${ENDPOINT}" >&2
  echo "       check the pod logs:" >&2
  echo "         kubectl -n ${ZGW_NAMESPACE} logs deploy/zgw-posix" >&2
  exit 1
fi

# trap handles port-forward teardown.

# ---- 5. next steps ----
cat <<EOF

zgw-posix is up in the dev cluster.
  image:       quay.io/dparkes/zgw-posix:latest
  namespace:   $ZGW_NAMESPACE
  in-cluster:  http://zgw-posix.$ZGW_NAMESPACE.svc.cluster.local
  creds:       access=$ZGW_ACCESS_KEY secret=$ZGW_SECRET_KEY (Secret zgw-posix-credentials)
  region:      $SMOKE_REGION

talk to it from a Tekton Task running in the cluster:
  --endpoint-url http://zgw-posix.$ZGW_NAMESPACE.svc.cluster.local
  ...with envFrom: secretRef name: zgw-posix-credentials (in any namespace
  that has copied the Secret across; or use a downward-mount pattern).

talk to it from your laptop:
  kubectl -n $ZGW_NAMESPACE port-forward svc/zgw-posix 18080:80 &
  AWS_ACCESS_KEY_ID=$ZGW_ACCESS_KEY \\
  AWS_SECRET_ACCESS_KEY=$ZGW_SECRET_KEY \\
    aws --endpoint-url http://localhost:18080 --region $SMOKE_REGION \\
        s3api list-buckets

teardown of just zgw-posix (leaves the rest of the dev cluster intact):
  kubectl delete -k $REPO_ROOT/kustomize/base/zgw-posix/
  # the PVC's PV will be reaped by local-path-provisioner once
  # the namespace deletion finalizes.

EOF

#!/usr/bin/env bash
# assert-zgw-posix-up.sh — confirm the in-cluster zgw-posix S3 endpoint
# is reachable and exercises the basic S3 wire format.
#
# Pass criteria:
#   1. The zgw-posix Deployment reports Available=True.
#   2. Port-forwarded `aws s3api list-buckets` returns cleanly (empty
#      bucket array on a fresh deploy is fine — the success criterion
#      is the auth+HTTP round trip).
#   3. Create-bucket → PUT object → GET object (byte-identical) →
#      delete-object → delete-bucket all succeed in sequence.
#
# Wired ahead of assert-vuln-scan-smoke.sh in run-all.sh because
# vuln-scan-smoke will eventually point its `db-pointer-url` at
# zgw-posix instead of standing up its own busybox httpd pod, and the
# earlier we confirm zgw-posix is alive the earlier we fail-fast if
# the kustomize base regressed.
#
# Prereqs:
#   - `make dev-up` (which now applies the zgw-posix base via the
#     dev-local overlay), OR `hack/dev-zgw-up.sh` against an
#     already-running dev cluster.
#
# Local re-runs: idempotent. The bucket name is suffixed with a
# timestamp so back-to-back runs don't collide. Trap-cleanup removes
# the bucket + object + port-forward on exit, success or failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-zgw-posix}"
DEPLOY="${DEPLOY:-zgw-posix}"
SVC="${SVC:-zgw-posix}"
ACCESS_KEY="${ACCESS_KEY:-cephtekton}"
SECRET_KEY="${SECRET_KEY:-cephtekton}"
REGION="${REGION:-default}"
# Use a per-run bucket name so re-runs against the same cluster don't
# collide. zgw-posix's POSIX backend doesn't have hard quota on bucket
# count for the dev workload size; if a previous failed run left a
# bucket behind, the cleanup at the bottom of this script handles it
# on the *next* run via best-effort delete.
BUCKET="zgw-smoke-$(date -u +%s)"
KEY="smoke/object.txt"
# Port-forward to a high port that won't collide with the laptop's
# usual suspects. 18081 picks one over from hack/dev-zgw-up.sh's
# default so a contributor running both side by side doesn't EADDRINUSE.
LOCAL_PORT="${LOCAL_PORT:-18081}"

log::info "=== assert-zgw-posix-up ==="

require_cmd kubectl "brew install kubectl"
require_cmd aws     "brew install awscli"

# ---- 1. Deployment Available? --------------------------------------
log::info "checking ${NS}/${DEPLOY} is Available"
if ! kube_ctx -n "${NS}" get deploy "${DEPLOY}" >/dev/null 2>&1; then
  log::fail "Deployment ${NS}/${DEPLOY} not found — did the dev-local overlay apply?"
  log::fail "  try: kubectl apply -k kustomize/base/zgw-posix/"
  exit 1
fi

# `kubectl wait --for=condition=Available` returns 0 once the
# Deployment controller flips that condition to True. 120s covers a
# cold image pull on most kind hosts.
if ! kube_ctx -n "${NS}" wait --for=condition=Available deploy/"${DEPLOY}" \
     --timeout="${E2E_ZGW_READY_TIMEOUT:-120s}"; then
  log::fail "Deployment ${NS}/${DEPLOY} did not become Available"
  kube_ctx -n "${NS}" describe deploy "${DEPLOY}" >&2 || true
  kube_ctx -n "${NS}" get pods -l app=zgw-posix -o wide >&2 || true
  exit 1
fi
log::pass "Deployment ${NS}/${DEPLOY} is Available"

# ---- 2. port-forward + smoke S3 list-buckets ------------------------
log::info "port-forwarding svc/${SVC} to localhost:${LOCAL_PORT}"
PF_LOG="$(mktemp)"
PF_PID=""
cleanup() {
  # Best-effort: delete the test bucket if it's still around (most
  # failure paths leave it intact). Then tear down the port-forward.
  if [[ -n "${ENDPOINT:-}" ]]; then
    AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
    AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
      aws --endpoint-url "${ENDPOINT}" --region "${REGION}" \
        s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
  rm -f "${PF_LOG}"
}
trap cleanup EXIT

kube_ctx -n "${NS}" port-forward svc/"${SVC}" "${LOCAL_PORT}:80" >"${PF_LOG}" 2>&1 &
PF_PID=$!

# Wait for the listener to bind. kubectl prints "Forwarding from ..."
# once it's ready; if the process dies first, we bail and print logs.
for i in $(seq 1 20); do
  if grep -q "Forwarding from" "${PF_LOG}"; then
    break
  fi
  if ! kill -0 "${PF_PID}" 2>/dev/null; then
    log::fail "kubectl port-forward died before binding"
    cat "${PF_LOG}" >&2
    exit 1
  fi
  sleep 0.5
  if (( i == 20 )); then
    log::fail "port-forward did not bind within ~10s"
    cat "${PF_LOG}" >&2
    exit 1
  fi
done

ENDPOINT="http://127.0.0.1:${LOCAL_PORT}"
AWS_ARGS=(--endpoint-url "${ENDPOINT}" --region "${REGION}")

export AWS_ACCESS_KEY_ID="${ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${SECRET_KEY}"

log::info "smoke: aws s3api list-buckets"
if ! aws "${AWS_ARGS[@]}" s3api list-buckets >/dev/null; then
  log::fail "aws s3api list-buckets failed against ${ENDPOINT}"
  kube_ctx -n "${NS}" logs deploy/"${DEPLOY}" >&2 || true
  exit 1
fi
log::pass "list-buckets returned cleanly"

# ---- 3. create-bucket / PUT / GET / delete cycle --------------------
log::info "create bucket: ${BUCKET}"
if ! aws "${AWS_ARGS[@]}" s3api create-bucket --bucket "${BUCKET}" >/dev/null; then
  log::fail "create-bucket failed for ${BUCKET}"
  exit 1
fi
log::pass "bucket created"

# PUT a known payload.
PAYLOAD_FILE="$(mktemp)"
PAYLOAD="zgw-posix smoke $(date -u +%s)"
printf '%s\n' "${PAYLOAD}" >"${PAYLOAD_FILE}"

log::info "PUT object: s3://${BUCKET}/${KEY}"
if ! aws "${AWS_ARGS[@]}" s3api put-object \
       --bucket "${BUCKET}" --key "${KEY}" --body "${PAYLOAD_FILE}" >/dev/null; then
  log::fail "put-object failed"
  rm -f "${PAYLOAD_FILE}"
  exit 1
fi
log::pass "object PUT"

# GET it back and assert byte-identical.
GET_FILE="$(mktemp)"
log::info "GET object: s3://${BUCKET}/${KEY}"
if ! aws "${AWS_ARGS[@]}" s3api get-object \
       --bucket "${BUCKET}" --key "${KEY}" "${GET_FILE}" >/dev/null; then
  log::fail "get-object failed"
  rm -f "${PAYLOAD_FILE}" "${GET_FILE}"
  exit 1
fi

if ! cmp -s "${PAYLOAD_FILE}" "${GET_FILE}"; then
  log::fail "GET object body did not match PUT body"
  diff "${PAYLOAD_FILE}" "${GET_FILE}" >&2 || true
  rm -f "${PAYLOAD_FILE}" "${GET_FILE}"
  exit 1
fi
log::pass "GET body byte-identical to PUT"
rm -f "${PAYLOAD_FILE}" "${GET_FILE}"

# Delete the object, then the bucket.
log::info "DELETE object then bucket"
aws "${AWS_ARGS[@]}" s3api delete-object \
  --bucket "${BUCKET}" --key "${KEY}" >/dev/null \
  || { log::fail "delete-object failed"; exit 1; }
aws "${AWS_ARGS[@]}" s3api delete-bucket --bucket "${BUCKET}" >/dev/null \
  || { log::fail "delete-bucket failed"; exit 1; }
log::pass "cleanup OK"

log::pass "assert-zgw-posix-up OK"

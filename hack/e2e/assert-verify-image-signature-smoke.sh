#!/usr/bin/env bash
# assert-verify-image-signature-smoke.sh — run
# pipelines/pipelines/verify-image-signature-smoke-test.yaml end-to-end
# and assert the in-pipeline cosign-verify flow that #92 introduced.
#
# Pass criteria:
#   1. The PipelineRun reaches Succeeded.
#   2. The `verify` TaskRun emits the four Results the Task documents:
#        * `verified`              — literal "true"
#        * `subject-digest`        — sha256:<64-hex> matching the
#                                    pushed image's digest
#        * `certificate-identity`  — empty (smoke is KEYED mode)
#        * `signing-time`          — empty (smoke uses ignore-tlog=true)
#   3. The `assert-results` TaskRun (Pipeline-internal) passes its
#      shape checks.
#
# Mechanism:
#   1. Re-deploy registry:2 to ns/e2e-registry if assert-build-builder-image
#      hasn't run yet (idempotent — same Deployment + Service shape).
#   2. Port-forward svc/registry → localhost:${REGISTRY_LOCAL_PORT}.
#   3. Mirror a tiny upstream image (busybox) into the in-cluster
#      registry via `crane copy`. The host writes via the port-forward;
#      the in-cluster verify Task reaches the same content via the
#      Service DNS name. Content-addressed digests are identical.
#   4. Generate an ephemeral cosign keypair (host-side).
#   5. `cosign sign` against the localhost: registry path so the
#      .sig artifact lands in the same registry the verify Task reads.
#   6. Create a Secret in the test namespace holding cosign.pub.
#   7. Apply the verify-image-signature Task, the smoke assert Task,
#      and the smoke Pipeline.
#   8. Start a PipelineRun with the digest-form image ref using the
#      Service DNS hostname; verify in-cluster.
#   9. Read Results off the verify TaskRun and assert shape.
#
# Prereqs on the test host:
#   - kubectl, tkn, jq      — universal e2e prereqs
#   - crane                 — image push to in-cluster registry
#   - cosign                — ephemeral key + sign
#
# Why crane and not skopeo / docker pull|push: crane is a single static
# Go binary that the assert-build-builder-image flow already vendors
# (used there inside a one-shot Pod for digest verification). Same
# dependency, this script pulls it in via require_cmd so dev hosts
# without crane get a clear install hint.
#
# Why ephemeral cosign keys and not the dev signing-secrets Secret:
# the tekton-chains signing-secrets keypair is reserved for Chains'
# OWN attestations (the dev-chains-setup.sh path). Mixing the verify
# smoke into that key would couple two unrelated trust chains; the
# ephemeral keys here are bounded to this script's lifetime + this
# test image only.
#
# Local re-runs: idempotent. The test image repo gets a per-run suffix
# so two back-to-back runs don't see each other's signature in the
# registry's content store. trap-cleanup deletes the ephemeral Secret,
# kills the port-forward, removes the per-run keys.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"
REGISTRY_NS="${REGISTRY_NS:-e2e-registry}"
REGISTRY_SERVICE="${REGISTRY_SERVICE:-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_INTERNAL="${REGISTRY_SERVICE}.${REGISTRY_NS}.svc:${REGISTRY_PORT}"

# Host-side port-forward target. Distinct from REGISTRY_PORT so we don't
# collide with anything else on the host bound to :5000.
REGISTRY_LOCAL_PORT="${REGISTRY_LOCAL_PORT:-15000}"

# Source image we mirror into the test registry. Tiny + public; the
# pin matches the busybox version the rest of this repo's smokes pull
# for tools-image, so the local crane cache is warm.
SOURCE_IMAGE="${SOURCE_IMAGE:-docker.io/library/busybox:1.36}"

# Per-run repo so re-runs don't collide on registry content.
RUN_TAG="$(date -u +%s)"
TEST_REPO="${TEST_REPO:-verify-smoke/test-${RUN_TAG}}"
TEST_TAG="${TEST_TAG:-v1}"

# Ephemeral cosign Secret name (cleaned up by trap).
PUBKEY_SECRET="verify-smoke-pubkey-${RUN_TAG}"

log::info "=== assert-verify-image-signature-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"
require_cmd crane   "brew install crane  (or: go install github.com/google/go-containerregistry/cmd/crane@latest)"
require_cmd cosign  "brew install cosign"

# ---------------------------------------------------------------------
# Stage 1: ensure in-cluster registry:2 exists.
#
# Same Deployment + Service shape as assert-build-builder-image.sh, so
# re-running this script after that one (or vice versa) is a no-op.
# Idempotent apply means we don't care about order.
# ---------------------------------------------------------------------
log::info "ensuring in-cluster registry in ns/${REGISTRY_NS}..."
kube_ctx create namespace "${REGISTRY_NS}" --dry-run=client -o yaml \
  | kube_ctx apply -f - >/dev/null
kube_ctx -n "${REGISTRY_NS}" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${REGISTRY_SERVICE}
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${REGISTRY_SERVICE} }
  template:
    metadata:
      labels: { app: ${REGISTRY_SERVICE} }
    spec:
      containers:
        - name: registry
          image: docker.io/library/registry:2.8
          ports:
            - containerPort: ${REGISTRY_PORT}
          env:
            - name: REGISTRY_HTTP_ADDR
              value: 0.0.0.0:${REGISTRY_PORT}
          volumeMounts:
            - name: registry-data
              mountPath: /var/lib/registry
      volumes:
        - name: registry-data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${REGISTRY_SERVICE}
spec:
  selector: { app: ${REGISTRY_SERVICE} }
  ports:
    - port: ${REGISTRY_PORT}
      targetPort: ${REGISTRY_PORT}
EOF
kube_ctx -n "${REGISTRY_NS}" rollout status deploy/${REGISTRY_SERVICE} --timeout=120s >/dev/null

# ---------------------------------------------------------------------
# Stage 2: port-forward + cleanup trap.
# ---------------------------------------------------------------------
WORK_DIR="${E2E_ARTIFACTS}/verify-image-signature"
mkdir -p "${WORK_DIR}"
KEY_DIR="${WORK_DIR}/keys-${RUN_TAG}"
mkdir -p "${KEY_DIR}"

PF_LOG="$(mktemp)"
PF_PID=""

cleanup() {
  # Best-effort. trap fires even on success so we always clean.
  kube_ctx -n "${NS}" delete secret "${PUBKEY_SECRET}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
  rm -f "${PF_LOG}"
  # Don't tear down the registry — re-runs reuse it.
  # Keys live under WORK_DIR/keys-<run-tag>; leave them for forensics.
}
trap cleanup EXIT

log::info "port-forwarding svc/${REGISTRY_SERVICE} → localhost:${REGISTRY_LOCAL_PORT}"
kube_ctx -n "${REGISTRY_NS}" port-forward svc/"${REGISTRY_SERVICE}" \
  "${REGISTRY_LOCAL_PORT}:${REGISTRY_PORT}" >"${PF_LOG}" 2>&1 &
PF_PID=$!

# Same bind-wait pattern as assert-vuln-scan-smoke.sh.
for i in $(seq 1 20); do
  if grep -q "Forwarding from" "${PF_LOG}"; then break; fi
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

LOCAL_REGISTRY="127.0.0.1:${REGISTRY_LOCAL_PORT}"
LOCAL_IMAGE="${LOCAL_REGISTRY}/${TEST_REPO}:${TEST_TAG}"
INTERNAL_IMAGE_BASE="${REGISTRY_INTERNAL}/${TEST_REPO}"

# ---------------------------------------------------------------------
# Stage 3: mirror SOURCE_IMAGE into the in-cluster registry.
#
# crane copy resolves SOURCE_IMAGE → digest from its upstream registry,
# pushes layers + manifest into LOCAL_REGISTRY under the chosen path.
# --insecure because the in-cluster registry serves HTTP.
# ---------------------------------------------------------------------
log::info "mirroring ${SOURCE_IMAGE} → ${LOCAL_IMAGE}"
crane copy --insecure "${SOURCE_IMAGE}" "${LOCAL_IMAGE}"

# Resolve the just-pushed image's digest. Content-addressed: same value
# whether we ask via localhost or via the Service DNS later.
PUSHED_DIGEST="$(crane digest --insecure "${LOCAL_IMAGE}")"
if ! printf '%s' "${PUSHED_DIGEST}" | grep -qE '^sha256:[0-9a-f]{64}$'; then
  log::fail "crane digest returned malformed value: '${PUSHED_DIGEST}'"
  exit 1
fi
log::info "pushed digest: ${PUSHED_DIGEST}"

LOCAL_DIGEST_IMAGE="${LOCAL_REGISTRY}/${TEST_REPO}@${PUSHED_DIGEST}"
INTERNAL_DIGEST_IMAGE="${INTERNAL_IMAGE_BASE}@${PUSHED_DIGEST}"

# ---------------------------------------------------------------------
# Stage 4: generate ephemeral cosign keypair + sign the image.
# ---------------------------------------------------------------------
log::info "generating ephemeral cosign keypair under ${KEY_DIR}"
( cd "${KEY_DIR}" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null )
COSIGN_PRIV="${KEY_DIR}/cosign.key"
COSIGN_PUB="${KEY_DIR}/cosign.pub"

log::info "cosign sign ${LOCAL_DIGEST_IMAGE}"
# --allow-insecure-registry: HTTP-only in-cluster registry.
# --insecure-ignore-tlog + --tlog-upload=false: don't talk to Rekor
# (ephemeral key, would pollute the public log and add network egress
# to every smoke run). Verify side passes the same --insecure-ignore-tlog.
# --yes: skip interactive confirmation prompts.
COSIGN_PASSWORD="" cosign sign \
  --key "${COSIGN_PRIV}" \
  --allow-insecure-registry \
  --tlog-upload=false \
  --yes \
  "${LOCAL_DIGEST_IMAGE}" >/dev/null

log::info "verifying the signature round-trips locally before in-cluster verify"
# Catch sign-side errors with the host's full cosign binary diagnostics
# before we wire up the Tekton path. If THIS fails the Task can't pass.
if ! COSIGN_PASSWORD="" cosign verify \
       --key "${COSIGN_PUB}" \
       --allow-insecure-registry \
       --insecure-ignore-tlog \
       "${LOCAL_DIGEST_IMAGE}" >/dev/null 2>"${WORK_DIR}/host-verify.txt"; then
  log::fail "host-side cosign verify failed BEFORE submitting to Tekton:"
  cat "${WORK_DIR}/host-verify.txt" >&2
  exit 1
fi
log::pass "host-side round-trip OK"

# ---------------------------------------------------------------------
# Stage 5: project cosign.pub into the test namespace as a Secret.
#
# The Pipeline binds workspace cosign-public-key to this Secret. Tekton
# projects the Secret's keys as files under the workspace mountPath
# (so cosign.pub key → /workspace/cosign-public-key/cosign.pub).
# ---------------------------------------------------------------------
log::info "creating Secret ${NS}/${PUBKEY_SECRET} from ${COSIGN_PUB##*/}"
kube_ctx -n "${NS}" create secret generic "${PUBKEY_SECRET}" \
  --from-file=cosign.pub="${COSIGN_PUB}" \
  --dry-run=client -o yaml | kube_ctx apply -f - >/dev/null

# ---------------------------------------------------------------------
# Stage 6: apply Task + Pipeline manifests.
# ---------------------------------------------------------------------
log::info "applying tasks/verify-image-signature/ + pipelines/tasks/verify-image-signature-smoke-assert + pipelines/pipelines/verify-image-signature-smoke-test ..."
kube_ctx apply -f "${E2E_REPO_ROOT}/tasks/verify-image-signature/task.yaml" >/dev/null
kube_ctx apply -f "${E2E_REPO_ROOT}/pipelines/tasks/verify-image-signature-smoke-assert.yaml" >/dev/null
kube_ctx apply -f "${E2E_REPO_ROOT}/pipelines/pipelines/verify-image-signature-smoke-test.yaml" >/dev/null

# ---------------------------------------------------------------------
# Stage 7: start the PipelineRun.
# ---------------------------------------------------------------------
log::info "starting verify-image-signature-smoke-test PipelineRun"
log::info "  image=${INTERNAL_DIGEST_IMAGE}"
PR="$(start_pipelinerun "${NS}" verify-image-signature-smoke-test \
        --param="image=${INTERNAL_DIGEST_IMAGE}" \
        --workspace="name=cosign-public-key,secret=${PUBKEY_SECRET}")"
log::info "started PipelineRun: ${NS}/${PR}"

wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "verify-image-signature-smoke-test PipelineRun did not Succeed"; exit 1; }

# ---------------------------------------------------------------------
# Stage 8: assert Results on the verify TaskRun.
#
# The smoke pipeline's own assert step has already failed the run if
# Results were malformed (Stage 7 wouldn't have reached Succeeded).
# We re-read here as a belt-and-braces check AND to log the values
# in the e2e harness's output for human review.
# ---------------------------------------------------------------------
VERIFY_TR="$(get_taskrun_for "${NS}" "${PR}" verify)"
[[ -n "${VERIFY_TR}" ]] || { log::fail "no verify TaskRun found"; exit 1; }
log::info "verify TaskRun: ${VERIFY_TR}"

R_VERIFIED="$(get_taskrun_result "${NS}" "${VERIFY_TR}" verified || true)"
R_SUBJECT_DIGEST="$(get_taskrun_result "${NS}" "${VERIFY_TR}" subject-digest || true)"
R_CERT_IDENTITY="$(get_taskrun_result "${NS}" "${VERIFY_TR}" certificate-identity || true)"
R_SIGNING_TIME="$(get_taskrun_result "${NS}" "${VERIFY_TR}" signing-time || true)"

log::info "verified='${R_VERIFIED}'"
log::info "subject-digest='${R_SUBJECT_DIGEST}'"
log::info "certificate-identity='${R_CERT_IDENTITY}'"
log::info "signing-time='${R_SIGNING_TIME}'"

FAIL=0

# verified MUST be the literal "true".
if [[ "${R_VERIFIED}" == "true" ]]; then
  log::pass "verified == 'true'"
else
  log::fail "verified == '${R_VERIFIED}'; expected literal 'true'"
  FAIL=1
fi

# subject-digest MUST equal the digest we pushed.
if [[ "${R_SUBJECT_DIGEST}" == "${PUSHED_DIGEST}" ]]; then
  log::pass "subject-digest matches pushed digest ${PUSHED_DIGEST}"
else
  log::fail "subject-digest mismatch — got '${R_SUBJECT_DIGEST}', expected '${PUSHED_DIGEST}'"
  FAIL=1
fi

# certificate-identity MUST be empty in keyed mode.
if [[ -z "${R_CERT_IDENTITY}" ]]; then
  log::pass "certificate-identity is empty (keyed mode)"
else
  log::fail "certificate-identity == '${R_CERT_IDENTITY}'; expected empty in keyed mode"
  FAIL=1
fi

# signing-time MUST be empty (ignore-tlog=true).
if [[ -z "${R_SIGNING_TIME}" ]]; then
  log::pass "signing-time is empty (ignore-tlog=true, no Rekor entry)"
else
  log::fail "signing-time == '${R_SIGNING_TIME}'; expected empty under ignore-tlog=true"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi

log::pass "assert-verify-image-signature-smoke OK"

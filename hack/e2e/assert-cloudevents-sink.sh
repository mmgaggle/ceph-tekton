#!/usr/bin/env bash
# assert-cloudevents-sink.sh — wire up the cloudevents-sink Deployment
# against the in-cluster zgw-posix S3 endpoint, POST a synthetic
# Tekton PipelineRun CloudEvent, assert the JSONL object lands in the
# events bucket with the expected shape (issue #63).
#
# Pass criteria:
#   1. The `ceph-tekton-events` bucket exists on zgw-posix (created
#      here; idempotent).
#   2. The cloudevents-sink Deployment becomes Available within the
#      timeout, with EVENTS_BUCKET + S3_ENDPOINT_URL + static AWS
#      creds patched in to point at zgw-posix.
#   3. /healthz returns 200 and /readyz returns 200 (the latter
#      requires the bucket exists; the assertion gates on readyz).
#   4. A POST of a synthetic CloudEvent (binary-mode HTTP) to
#      /cloudevents returns 202.
#   5. After the size-threshold flush fires (FLUSH_MAX_EVENTS=1 in
#      this assertion's env patch, so the first POST flushes
#      synchronously), exactly one object lands in
#      s3://ceph-tekton-events/events/dt=YYYY-MM-DD/hr=HH/<uuid>.jsonl.
#   6. The object's body parses as JSON-Lines with one record, and
#      the record's `type` + `subject` + `data.pipelineRun.metadata.name`
#      match what we POSTed.
#
# WHY exercise the sink directly with curl rather than driving Tekton
#     to emit CloudEvents:
# Wiring the kind dev cluster's vanilla Tekton Pipelines to actually
# emit CloudEvents needs a `kubectl patch configmap feature-flags`
# round trip and a PipelineRun whose lifecycle transitions the
# controller actually observes. The shape we want to test is "the
# sink correctly buffers, partitions, and flushes a CloudEvents-1.0
# binary-mode payload to S3" — POSTing one synthetic event with the
# exact Ce-* headers Tekton uses exercises that contract directly
# and runs in seconds. The "Tekton actually emits these events"
# integration is covered by the Sepia overlay's TektonConfig (the
# kind path can't reproduce it because the OpenShift Pipelines
# operator isn't installed there) and by the docs/build-archive.md
# §"Enabling Tekton CloudEvents" manual-verification procedure.
#
# Prereqs:
#   - kind cluster with Tekton (via `make dev-up`) — actually not
#     even strictly needed; this assertion only needs zgw-posix +
#     the sink image. But it runs as part of run-all.sh which has
#     Tekton up by the time this assertion fires.
#   - zgw-posix base applied + Ready (assert-zgw-posix-up.sh runs
#     before this assertion in run-all.sh's ordered list).
#   - A locally-built `ceph-tekton/cloudevents-sink:dev` image
#     loaded into the kind nodes (handled here via the loader fn).
#
# Local re-runs: idempotent. Each invocation creates a fresh
# CloudEvent id + subject, scans for the matching JSONL, and tolerates
# pre-existing objects in the bucket from prior runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# ---- knobs ---------------------------------------------------------
SINK_NS="${SINK_NS:-cloudevents-sink}"
SINK_DEPLOY="${SINK_DEPLOY:-cloudevents-sink}"
SINK_SVC="${SINK_SVC:-cloudevents-sink}"
SINK_IMAGE="${SINK_IMAGE:-ceph-tekton/cloudevents-sink:dev}"

ZGW_NS="${ZGW_NS:-zgw-posix}"
ZGW_SVC="${ZGW_SVC:-zgw-posix}"
ZGW_ACCESS_KEY="${ZGW_ACCESS_KEY:-cephtekton}"
ZGW_SECRET_KEY="${ZGW_SECRET_KEY:-cephtekton}"
ZGW_REGION="${ZGW_REGION:-default}"

EVENTS_BUCKET="${EVENTS_BUCKET:-ceph-tekton-events}"

# Per-run unique event identity so we can pinpoint our own JSONL
# regardless of what prior runs left in the bucket.
RUN_ID="$(date -u +%s)-$$"
EVENT_ID="e2e-${RUN_ID}"
EVENT_SUBJECT="e2e-pipelinerun-${RUN_ID}"
EVENT_TYPE="dev.tekton.event.pipelinerun.successful.v1"
PIPELINERUN_NAME="e2e-${RUN_ID}"
PIPELINE_NAME="e2e-cloudevents-sink-assert"

# Port-forwards. Use distinct high ports from the zgw-posix-up assert
# script so an interleaved test run doesn't EADDRINUSE.
SINK_LOCAL_PORT="${SINK_LOCAL_PORT:-18082}"
S3_LOCAL_PORT="${S3_LOCAL_PORT:-18083}"

log::info "=== assert-cloudevents-sink ==="

require_cmd kubectl "brew install kubectl"
require_cmd aws     "brew install awscli"
require_cmd curl    "brew install curl"
require_cmd jq      "brew install jq"

# ---- 0. Build + load the sink image into the kind cluster ----------
#
# The sink image isn't published anywhere yet (per the Dockerfile +
# README — image-build automation is follow-up work). For the e2e
# assert to deploy a real Pod we have to build the image on the runner
# and `kind load` it into the node so kubelet can resolve it without
# leaving the host.
#
# CONTAINER_RUNTIME detection mirrors hack/dev-up.sh — docker
# preferred, podman fallback. If neither is on PATH the build step
# bails with the same error dev-up would.
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-$(command -v docker || command -v podman || true)}"
if [[ -z "${CONTAINER_RUNTIME}" ]]; then
  log::fail "no container runtime found on PATH (need docker or podman)"
  exit 1
fi

# Image-loading path differs between docker- and podman-backed kind.
# `kind load docker-image` requires a docker daemon; for podman we use
# `kind load image-archive` against a saved tarball — slower but
# portable. The CI runner uses docker; the local-dev podman path is
# documented but rarely exercised here.
load_image_into_kind() {
  local img="$1" cluster="$2"
  if [[ "${CONTAINER_RUNTIME}" == *docker* ]]; then
    kind load docker-image "${img}" --name "${cluster}"
  else
    local tar
    tar="$(mktemp -t ce-sink-XXXX.tar)"
    "${CONTAINER_RUNTIME}" save -o "${tar}" "${img}"
    kind load image-archive "${tar}" --name "${cluster}"
    rm -f "${tar}"
  fi
}

# kind cluster name — match lib.sh's E2E_KIND_CLUSTER (default "e2e";
# the local-dev cluster is "ceph-tekton-dev" but contributors running
# this assertion against their dev cluster set E2E_KIND_CLUSTER
# explicitly, same way the other asserts work).
log::info "building sink image: ${SINK_IMAGE}"
( cd "${E2E_REPO_ROOT}/services/cloudevents-sink" \
  && "${CONTAINER_RUNTIME}" build -t "${SINK_IMAGE}" . ) >/dev/null

log::info "loading sink image into kind cluster ${E2E_KIND_CLUSTER}"
load_image_into_kind "${SINK_IMAGE}" "${E2E_KIND_CLUSTER}"

# ---- 1. Make sure the events bucket exists on zgw-posix ------------
#
# The sink's /readyz HEADs the bucket — without it, the readiness
# probe fails and the Deployment never reports Available. zgw-posix
# isn't reconciled by terraform in the kind path; we PUT the bucket
# directly from the runner via a port-forward.
log::info "port-forward zgw-posix svc to localhost:${S3_LOCAL_PORT}"
ZGW_PF_LOG="$(mktemp)"
ZGW_PF_PID=""
SINK_PF_LOG="$(mktemp)"
SINK_PF_PID=""
cleanup() {
  if [[ -n "${SINK_PF_PID}" ]] && kill -0 "${SINK_PF_PID}" 2>/dev/null; then
    kill "${SINK_PF_PID}" 2>/dev/null || true
    wait "${SINK_PF_PID}" 2>/dev/null || true
  fi
  if [[ -n "${ZGW_PF_PID}" ]] && kill -0 "${ZGW_PF_PID}" 2>/dev/null; then
    kill "${ZGW_PF_PID}" 2>/dev/null || true
    wait "${ZGW_PF_PID}" 2>/dev/null || true
  fi
  rm -f "${ZGW_PF_LOG}" "${SINK_PF_LOG}"
}
trap cleanup EXIT

kube_ctx -n "${ZGW_NS}" port-forward svc/"${ZGW_SVC}" \
  "${S3_LOCAL_PORT}:80" >"${ZGW_PF_LOG}" 2>&1 &
ZGW_PF_PID=$!

# Wait for the listener to bind. Same pattern assert-zgw-posix-up uses.
for i in $(seq 1 20); do
  if grep -q "Forwarding from" "${ZGW_PF_LOG}"; then break; fi
  if ! kill -0 "${ZGW_PF_PID}" 2>/dev/null; then
    log::fail "zgw-posix port-forward died before binding"
    cat "${ZGW_PF_LOG}" >&2
    exit 1
  fi
  sleep 0.5
  if (( i == 20 )); then
    log::fail "zgw-posix port-forward did not bind within ~10s"
    cat "${ZGW_PF_LOG}" >&2
    exit 1
  fi
done

ZGW_ENDPOINT="http://127.0.0.1:${S3_LOCAL_PORT}"
export AWS_ACCESS_KEY_ID="${ZGW_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${ZGW_SECRET_KEY}"
AWS_ARGS=(--endpoint-url "${ZGW_ENDPOINT}" --region "${ZGW_REGION}")

# create-bucket is idempotent-ish: zgw-posix returns BucketAlreadyOwnedByYou
# for a second create from the same creds. Accept either path so re-runs
# against an already-bootstrapped bucket are clean.
log::info "ensure bucket ${EVENTS_BUCKET} exists on zgw-posix"
if ! aws "${AWS_ARGS[@]}" s3api create-bucket \
       --bucket "${EVENTS_BUCKET}" >/dev/null 2>&1; then
  # Distinguish "already exists" (fine) from a real failure (fatal).
  if aws "${AWS_ARGS[@]}" s3api head-bucket \
       --bucket "${EVENTS_BUCKET}" >/dev/null 2>&1; then
    log::info "  bucket already exists — continuing"
  else
    log::fail "create-bucket failed and bucket does not exist"
    exit 1
  fi
fi

# ---- 2. Apply the cloudevents-sink base + patch env for zgw-posix --
#
# The base ships with EVENTS_BUCKET / S3_ENDPOINT_URL / AWS_REGION
# placeholders the per-env overlay normally tunes. For the kind path
# we don't have a kustomize overlay (the dev-{local,kind} overlays
# deliberately don't pull in cloudevents-sink — the sink is not part
# of the everyday dev loop). We apply the base then `kubectl set env`
# the deployment to point at zgw-posix and inject the static creds.
log::info "apply kustomize/base/cloudevents-sink/"
kube_ctx apply -k "${E2E_REPO_ROOT}/kustomize/base/cloudevents-sink/" >/dev/null

# Patch in zgw-posix endpoint + creds + flush-thresholds tuned for
# the assertion (size threshold = 1 so the single POST below flushes
# synchronously; interval = 5s as a backstop). The sink's image was
# loaded above; we also flip imagePullPolicy to Never so kubelet
# doesn't try to refresh from a public registry (the image isn't
# pushed anywhere).
log::info "patch Deployment env for zgw-posix + immediate flush"
kube_ctx -n "${SINK_NS}" set image deploy/"${SINK_DEPLOY}" \
  "sink=${SINK_IMAGE}" >/dev/null
kube_ctx -n "${SINK_NS}" patch deploy "${SINK_DEPLOY}" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}
]' >/dev/null
kube_ctx -n "${SINK_NS}" set env deploy/"${SINK_DEPLOY}" \
  EVENTS_BUCKET="${EVENTS_BUCKET}" \
  S3_ENDPOINT_URL="http://${ZGW_SVC}.${ZGW_NS}.svc.cluster.local" \
  AWS_REGION="${ZGW_REGION}" \
  AWS_ACCESS_KEY_ID="${ZGW_ACCESS_KEY}" \
  AWS_SECRET_ACCESS_KEY="${ZGW_SECRET_KEY}" \
  FLUSH_MAX_EVENTS=1 \
  FLUSH_MAX_INTERVAL_SECONDS=5 >/dev/null

# ---- 3. Wait for the Deployment to become Available ----------------
log::info "wait for ${SINK_NS}/${SINK_DEPLOY} Available"
if ! kube_ctx -n "${SINK_NS}" wait --for=condition=Available \
     deploy/"${SINK_DEPLOY}" \
     --timeout="${E2E_SINK_READY_TIMEOUT:-180s}"; then
  log::fail "Deployment ${SINK_NS}/${SINK_DEPLOY} did not become Available"
  kube_ctx -n "${SINK_NS}" describe deploy "${SINK_DEPLOY}" >&2 || true
  kube_ctx -n "${SINK_NS}" get pods -l app=cloudevents-sink -o wide >&2 || true
  kube_ctx -n "${SINK_NS}" logs deploy/"${SINK_DEPLOY}" --tail=200 >&2 || true
  exit 1
fi
log::pass "Deployment ${SINK_NS}/${SINK_DEPLOY} is Available"

# ---- 4. Port-forward the sink + healthcheck ------------------------
log::info "port-forward svc/${SINK_SVC} to localhost:${SINK_LOCAL_PORT}"
kube_ctx -n "${SINK_NS}" port-forward svc/"${SINK_SVC}" \
  "${SINK_LOCAL_PORT}:80" >"${SINK_PF_LOG}" 2>&1 &
SINK_PF_PID=$!

for i in $(seq 1 20); do
  if grep -q "Forwarding from" "${SINK_PF_LOG}"; then break; fi
  if ! kill -0 "${SINK_PF_PID}" 2>/dev/null; then
    log::fail "sink port-forward died before binding"
    cat "${SINK_PF_LOG}" >&2
    exit 1
  fi
  sleep 0.5
  if (( i == 20 )); then
    log::fail "sink port-forward did not bind within ~10s"
    cat "${SINK_PF_LOG}" >&2
    exit 1
  fi
done

SINK_URL="http://127.0.0.1:${SINK_LOCAL_PORT}"

log::info "GET ${SINK_URL}/healthz"
if ! curl --fail --silent --show-error "${SINK_URL}/healthz" >/dev/null; then
  log::fail "sink /healthz did not return 200"
  exit 1
fi
log::pass "/healthz OK"

log::info "GET ${SINK_URL}/readyz"
if ! curl --fail --silent --show-error "${SINK_URL}/readyz" >/dev/null; then
  log::fail "sink /readyz did not return 200 (bucket reach?)"
  kube_ctx -n "${SINK_NS}" logs deploy/"${SINK_DEPLOY}" --tail=100 >&2 || true
  exit 1
fi
log::pass "/readyz OK"

# ---- 5. POST a synthetic CloudEvent (binary mode) ------------------
#
# Shape mirrors Tekton's `tektoncd/pipeline` controller's CloudEvents
# emitter: binary-mode HTTP, Ce-* headers carry the envelope, body is
# the data payload as JSON. The `data.pipelineRun` shape is the
# trimmed-down PipelineRun status object that Tekton serializes when
# it constructs the event. We only carry the fields the sink's
# analytics consumers downstream actually read (name, namespace, uid,
# status conditions, completion time) — anything else in a real
# PipelineRun envelope would survive a JSON round trip unchanged.
POST_BODY="$(jq -nc \
  --arg name "${PIPELINERUN_NAME}" \
  --arg pipeline "${PIPELINE_NAME}" \
  --arg ns "ceph-builds" \
  --arg uid "uid-${RUN_ID}" \
  '{
    pipelineRun: {
      metadata: {
        name: $name,
        namespace: $ns,
        uid: $uid,
        labels: {
          "tekton.dev/pipeline": $pipeline
        }
      },
      status: {
        completionTime: "2026-05-25T17:42:01Z",
        startTime:      "2026-05-25T17:38:12Z",
        conditions: [
          { type: "Succeeded", status: "True", reason: "Succeeded" }
        ]
      }
    }
  }')"

log::info "POST synthetic CloudEvent (type=${EVENT_TYPE} id=${EVENT_ID})"
HTTP_OUT="$(mktemp)"
HTTP_STATUS="$(
  curl --silent --show-error --output "${HTTP_OUT}" \
       --write-out '%{http_code}' \
       -X POST "${SINK_URL}/cloudevents" \
       -H 'Content-Type: application/json' \
       -H "Ce-Specversion: 1.0" \
       -H "Ce-Id: ${EVENT_ID}" \
       -H "Ce-Source: /apis/tekton.dev/v1beta1/namespaces/ceph-builds/pipelineruns/${PIPELINERUN_NAME}" \
       -H "Ce-Type: ${EVENT_TYPE}" \
       -H "Ce-Subject: ${EVENT_SUBJECT}" \
       -H "Ce-Time: 2026-05-25T17:42:00Z" \
       -H "Ce-Datacontenttype: application/json" \
       --data "${POST_BODY}"
)"
if [[ "${HTTP_STATUS}" != "202" ]]; then
  log::fail "POST /cloudevents returned ${HTTP_STATUS} (expected 202)"
  log::fail "  body:"
  cat "${HTTP_OUT}" >&2 || true
  exit 1
fi
rm -f "${HTTP_OUT}"
log::pass "POST returned 202"

# ---- 6. Scan the events bucket for our JSONL -----------------------
#
# FLUSH_MAX_EVENTS=1 means the size threshold tripped synchronously
# inside the POST handler (see sink.py: `flush(reason="size")` runs
# before the 202 returns). The PUT to S3 has therefore already
# completed by the time we get here — no sleep needed in the
# happy path. We still poll for up to E2E_SINK_FLUSH_TIMEOUT (default
# 30s) to absorb any zgw-posix RTT jitter on the runner.
log::info "scan bucket for the flushed JSONL"

# Get today's UTC partition so we list the precise prefix the sink
# wrote to. dt=YYYY-MM-DD/hr=HH per the layout in sink.py:_key_for_now.
DT_PARTITION="$(date -u '+events/dt=%Y-%m-%d/hr=%H')"

FOUND=""
DEADLINE=$(( SECONDS + ${E2E_SINK_FLUSH_TIMEOUT:-30} ))
while [[ -z "${FOUND}" ]] && (( SECONDS < DEADLINE )); do
  # List under the date+hour partition. zgw-posix returns an empty
  # Contents list if nothing exists yet; the loop tolerates the
  # eventual-consistency window.
  KEYS="$(aws "${AWS_ARGS[@]}" s3api list-objects-v2 \
            --bucket "${EVENTS_BUCKET}" \
            --prefix "${DT_PARTITION}/" \
            --query 'Contents[].Key' \
            --output text 2>/dev/null || true)"
  if [[ -z "${KEYS}" || "${KEYS}" == "None" ]]; then
    sleep 1
    continue
  fi
  # For each candidate, GET + grep for our unique event id. We can't
  # rely on filename matching since the JSONL is uuid-keyed and a
  # batch may have multiple events.
  for key in ${KEYS}; do
    [[ "${key}" == "None" ]] && continue
    OBJ="$(mktemp)"
    if aws "${AWS_ARGS[@]}" s3api get-object \
         --bucket "${EVENTS_BUCKET}" --key "${key}" "${OBJ}" >/dev/null 2>&1; then
      if grep -qF "\"${EVENT_ID}\"" "${OBJ}" 2>/dev/null; then
        FOUND="${key}"
        FOUND_FILE="${OBJ}"
        break 2
      fi
    fi
    rm -f "${OBJ}"
  done
  sleep 1
done

if [[ -z "${FOUND}" ]]; then
  log::fail "no JSONL containing event id ${EVENT_ID} appeared in"
  log::fail "  s3://${EVENTS_BUCKET}/${DT_PARTITION}/ within ${E2E_SINK_FLUSH_TIMEOUT:-30}s"
  kube_ctx -n "${SINK_NS}" logs deploy/"${SINK_DEPLOY}" --tail=200 >&2 || true
  exit 1
fi
log::pass "JSONL landed at s3://${EVENTS_BUCKET}/${FOUND}"

# ---- 7. Assert JSONL shape -----------------------------------------
#
# Find the record matching our event id (the file may contain other
# records if a prior test left a flush in the same partition window).
# Validate the envelope shape sink.py constructs in binary mode.
RECORD="$(jq -c --arg id "${EVENT_ID}" \
            'select(.id == $id)' "${FOUND_FILE}" | head -n1)"
if [[ -z "${RECORD}" ]]; then
  log::fail "JSONL contains no record with id=${EVENT_ID}"
  log::fail "  file content:"
  cat "${FOUND_FILE}" >&2 || true
  rm -f "${FOUND_FILE}"
  exit 1
fi

# Assertion bundle: jq -e returns non-zero on a false / null final
# value, so each `.` here is a structural check the sink must have
# preserved end-to-end.
if ! echo "${RECORD}" | jq -e \
       --arg type "${EVENT_TYPE}" \
       --arg subj "${EVENT_SUBJECT}" \
       --arg prn  "${PIPELINERUN_NAME}" '
         (.specversion == "1.0")
         and (.type    == $type)
         and (.subject == $subj)
         and (.data.pipelineRun.metadata.name == $prn)
         and (._headers["Ce-Id"] != null)
         and (._sink_received_at | type == "string")
         and (._sink_id          | type == "string")
       ' >/dev/null; then
  log::fail "JSONL record shape mismatch — got:"
  echo "${RECORD}" | jq . >&2 || true
  rm -f "${FOUND_FILE}"
  exit 1
fi
rm -f "${FOUND_FILE}"

log::pass "JSONL record shape matches expected (type, subject, data.pipelineRun.metadata.name)"
log::pass "assert-cloudevents-sink OK"

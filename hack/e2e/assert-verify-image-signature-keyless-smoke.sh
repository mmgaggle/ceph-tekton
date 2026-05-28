#!/usr/bin/env bash
# assert-verify-image-signature-keyless-smoke.sh — run
# pipelines/pipelines/verify-image-signature-keyless-smoke-test.yaml
# end-to-end and assert the KEYLESS verify flow (#94).
#
# Companion to the keyed driver (assert-verify-image-signature-smoke.sh).
# Where the keyed driver brings up an in-cluster registry, mirrors an
# image, generates ephemeral keys, signs, and projects a Secret, the
# keyless driver does NONE of that — it verifies a real public
# keyless-signed image (ghcr.io/sigstore/cosign/cosign:v2.4.1) whose
# Fulcio cert identity is documented in the Pipeline file's header
# and was verified empirically before pinning.
#
# Pass criteria:
#   1. The PipelineRun reaches Succeeded.
#   2. verify Task emits:
#        * `verified`              — literal "true"
#        * `subject-digest`        — equals the pinned image digest
#        * `certificate-identity`  — equals the param (echo-back)
#        * `signing-time`          — RFC 3339 UTC (Rekor entry
#                                    resolved; ignore-tlog=false)
#   3. The in-Pipeline assert-results Task passes its shape checks.
#
# Network requirements (in addition to the rest of the harness):
#   - egress to ghcr.io (image + .sig fetch) — universal CI need
#   - egress to rekor.sigstore.dev (tlog inclusion check) — also
#     needed by chains-smoke today; not a new dependency
#   - egress to oauth2.sigstore.dev / fulcio.sigstore.dev for root
#     trust bundle refresh (cosign embeds the bundle but may refresh)
#
# Rekor flake handling: the existing chains-smoke uses 3-attempt
# retries against the public Rekor instance. If this smoke flakes
# the same retry pattern can be added here; for now we trust a single
# attempt and let CI's job-level retry catch transient 5xx.
#
# Local re-runs: trivially idempotent — no per-run state, nothing to
# clean up. Re-running 10 times in a row hits the same image with the
# same signature against the same Rekor entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"

# Pinned image: ghcr.io/sigstore/cosign/cosign:v2.4.1 manifest-index
# digest, captured 2026-05-28. The smoke Pipeline default carries the
# same value — duplicated here so the assertion that
# subject-digest == this can use it as a literal. Keep both in sync;
# see the Pipeline header for the bump procedure.
EXPECTED_IMAGE_DIGEST="${EXPECTED_IMAGE_DIGEST:-sha256:b03690aa52bfe94054187142fba24dc54137650682810633901767d8a3e15b31}"
EXPECTED_CERT_IDENTITY="${EXPECTED_CERT_IDENTITY:-keyless@projectsigstore.iam.gserviceaccount.com}"

log::info "=== assert-verify-image-signature-keyless-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"
# No cosign / crane required on the host: the keyless smoke verifies
# a public image, with the in-cluster verify Task doing all the cosign
# work. Compare with the keyed driver, which needs both for host-side
# image mirroring + signing.

# ---------------------------------------------------------------------
# Stage 1: apply Task + Pipeline + assert Task.
#
# DEPENDS ON #93 — tasks/verify-image-signature/task.yaml and
# pipelines/tasks/verify-image-signature-smoke-assert.yaml must exist
# in the working tree. If this script is being run from a checkout
# that pre-dates #93 merging to main, the apply step fails with a
# "no such file" error from kubectl. That's the intended pre-flight
# signal — fix by rebasing onto post-#93 main.
# ---------------------------------------------------------------------
TASK_YAML="${E2E_REPO_ROOT}/tasks/verify-image-signature/task.yaml"
ASSERT_YAML="${E2E_REPO_ROOT}/pipelines/tasks/verify-image-signature-smoke-assert.yaml"
PIPELINE_YAML="${E2E_REPO_ROOT}/pipelines/pipelines/verify-image-signature-keyless-smoke-test.yaml"

for f in "${TASK_YAML}" "${ASSERT_YAML}" "${PIPELINE_YAML}"; do
  if [[ ! -f "${f}" ]]; then
    log::fail "missing required manifest: ${f}"
    log::fail "  (this smoke depends on #93 — the Task + assert ship there)"
    exit 1
  fi
done

log::info "applying tasks/verify-image-signature/ + smoke-assert + keyless Pipeline ..."
kube_ctx apply -f "${TASK_YAML}"     >/dev/null
kube_ctx apply -f "${ASSERT_YAML}"   >/dev/null
kube_ctx apply -f "${PIPELINE_YAML}" >/dev/null

# ---------------------------------------------------------------------
# Stage 2: start the PipelineRun against the Pipeline's pinned
# defaults (no --param overrides needed in CI; the Pipeline already
# carries the image / identity / issuer defaults).
# ---------------------------------------------------------------------
log::info "starting verify-image-signature-keyless-smoke-test PipelineRun"
log::info "  expecting subject-digest=${EXPECTED_IMAGE_DIGEST}"
log::info "  expecting certificate-identity=${EXPECTED_CERT_IDENTITY}"

PR="$(start_pipelinerun "${NS}" verify-image-signature-keyless-smoke-test)"
log::info "started PipelineRun: ${NS}/${PR}"

wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "verify-image-signature-keyless-smoke-test PipelineRun did not Succeed"; exit 1; }

# ---------------------------------------------------------------------
# Stage 3: read Results off the verify TaskRun, assert shape.
#
# The Pipeline's own assert-results Task has already failed the run
# on malformed Results (Stage 2 wouldn't have reached Succeeded).
# These checks are belt-and-braces AND log the values into the
# harness output for human review.
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

# subject-digest MUST match the pinned digest we expect cosign to be
# verifying. Drift here means either the pin in the Pipeline default
# moved (intentional bump — update EXPECTED_IMAGE_DIGEST too) or
# something is verifying a different image than we think (bug).
if [[ "${R_SUBJECT_DIGEST}" == "${EXPECTED_IMAGE_DIGEST}" ]]; then
  log::pass "subject-digest matches pinned digest ${EXPECTED_IMAGE_DIGEST}"
else
  log::fail "subject-digest mismatch — got '${R_SUBJECT_DIGEST}'"
  log::fail "                          expected '${EXPECTED_IMAGE_DIGEST}'"
  log::fail "  (if you intentionally bumped the Pipeline default, update"
  log::fail "   EXPECTED_IMAGE_DIGEST in this script + the issue body)"
  FAIL=1
fi

# certificate-identity MUST be the GCP SA we verified against — same
# echo-back contract as the keyed mode (where it's empty), with the
# specific non-empty value spelled out here.
if [[ "${R_CERT_IDENTITY}" == "${EXPECTED_CERT_IDENTITY}" ]]; then
  log::pass "certificate-identity matches expected ${EXPECTED_CERT_IDENTITY}"
else
  log::fail "certificate-identity mismatch — got '${R_CERT_IDENTITY}'"
  log::fail "                                expected '${EXPECTED_CERT_IDENTITY}'"
  FAIL=1
fi

# signing-time MUST be non-empty and shaped like RFC 3339 UTC (the
# Task's emit step uses busybox `date -u -d @<unix>` formatting). If
# the busybox date fallback fired (unlikely on the docker.io busybox
# pin we use everywhere), the Result would be a Unix-seconds integer
# — the keyed-smoke assert accepts either; we do the same.
if [[ -z "${R_SIGNING_TIME}" ]]; then
  log::fail "signing-time is empty; expected a Rekor integratedTime (ignore-tlog=false)"
  FAIL=1
elif [[ "${R_SIGNING_TIME}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  log::pass "signing-time is RFC 3339 UTC: ${R_SIGNING_TIME}"
elif [[ "${R_SIGNING_TIME}" =~ ^[0-9]{10}$ ]]; then
  log::pass "signing-time is Unix seconds (busybox date fallback): ${R_SIGNING_TIME}"
else
  log::fail "signing-time='${R_SIGNING_TIME}' is neither RFC 3339 nor Unix seconds"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi

log::pass "assert-verify-image-signature-keyless-smoke OK"

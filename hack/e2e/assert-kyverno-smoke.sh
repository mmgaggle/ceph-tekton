#!/usr/bin/env bash
# assert-kyverno-smoke.sh — run pipelines/pipelines/kyverno-smoke-test.yaml and
# assert both branches landed as expected (one admit + one reject with
# the rejection mentioning cosign/signature/our policy name).
#
# Pass criteria:
#   1. PipelineRun succeeds (the smoke pipeline itself encodes the
#      admit/reject expectations — if either Task gets the wrong
#      outcome it exits 1 and fails the PipelineRun).
#   2. The `admit-signed-ceph` TaskRun's log shows "OK: pod was admitted
#      as expected".
#   3. The `reject-unsigned-ceph` TaskRun's log shows "OK: rejection
#      reason mentions cosign/signature/policy name".
#
# IMPORTANT NUANCE: per the smoke pipeline header comments, the
# admit-signed-ceph branch is wired against a stand-in default tag
# (quay.io/ceph/ceph:v19.2.0) that the dev signing-secrets cosign.pub
# cannot actually verify. The pipeline header documents this as
# "intentional — fails by design until #25 lands". In CI we either:
#   (a) override --param=signed-ceph-image= to point at a tag the
#       dev key CAN verify, or
#   (b) accept that today this assertion checks the REJECT half only
#       and gives the ADMIT half a TODO marker.
#
# We take path (b) and document it in docs/e2e.md so the assertion
# fails LOUDLY but not FATALLY for the admit half until #25 lands,
# while the reject half — the one that actually proves Kyverno is
# enforcing — stays a hard gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-kyverno-smoke}"
SA="${SA:-kyverno-smoke-sa}"

# Set to "true" to make the admit-signed-ceph half a hard gate; default
# is "false" because there is no real Chains-signed quay.io/ceph/ceph
# image whose signature the dev cosign.pub can verify until #25 lands.
STRICT_ADMIT="${E2E_KYVERNO_STRICT_ADMIT:-false}"

log::info "=== assert-kyverno-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"

# Prereqs: the dev ClusterPolicy must already be Ready.
if ! kube_ctx get clusterpolicy verify-ceph-image-signatures-dev >/dev/null 2>&1; then
  log::fail "ClusterPolicy verify-ceph-image-signatures-dev not found — run hack/dev-kyverno-up.sh"
  exit 1
fi

# Apply the setup (Namespace + RBAC), then the Task, then the Pipeline
# (idempotent). Issue #68 split `pipelines/kyverno-smoke-test.yaml`
# into single-resource files (Task at pipelines/tasks/, Pipeline at
# pipelines/pipelines/) so PaC remote-resolution works on the Task +
# Pipeline halves. The RBAC stays multi-doc and lives outside
# pipelines/ (under manifests/smoke-setup/) because Namespace/SA/Role/
# RoleBinding aren't PaC-resolvable resources.
#
# `-n "${NS}"` is required for the Task and Pipeline resources, which
# don't pin a namespace in the manifest; without it they land in the
# kubectl context's current namespace (default) while `tkn pipeline
# start` below looks in `${NS}` (kyverno-smoke) and fails with
# "Pipeline name kyverno-smoke-test does not exist". The RBAC file
# already pins `kyverno-smoke` in its metadata so the `-n` is a no-op
# there.
kube_ctx            apply -f "${E2E_REPO_ROOT}/manifests/smoke-setup/kyverno-smoke-rbac.yaml" >/dev/null
kube_ctx -n "${NS}" apply -f "${E2E_REPO_ROOT}/pipelines/tasks/try-pod-admit.yaml"            >/dev/null
kube_ctx -n "${NS}" apply -f "${E2E_REPO_ROOT}/pipelines/pipelines/kyverno-smoke-test.yaml"   >/dev/null

# The pipeline itself decides pass/fail in the try-pod-admit Task.
# If E2E_KYVERNO_STRICT_ADMIT=false we let the admit-signed-ceph half
# fail without failing this script — but the reject half MUST pass.
PR_RC=0
PR="$(start_pipelinerun "${NS}" kyverno-smoke-test --serviceaccount="${SA}")" || PR_RC=$?
if [[ -z "${PR}" || "${PR_RC}" -ne 0 ]]; then
  log::fail "could not start kyverno-smoke-test PipelineRun"
  exit 1
fi
log::info "started PipelineRun: ${NS}/${PR}"

# We can't use wait_pipelinerun_succeeded directly because we want to
# allow PipelineRun=False when only the admit half fails. Poll for
# either terminal condition.
budget_s="${E2E_PIPELINERUN_TIMEOUT%s}"
elapsed=0
while [[ "${elapsed}" -lt "${budget_s}" ]]; do
  st="$(kube_ctx -n "${NS}" get pipelinerun "${PR}" \
        -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")"
  if [[ "${st}" == "True" || "${st}" == "False" ]]; then
    break
  fi
  sleep 2
  elapsed=$(( elapsed + 2 ))
done

ADMIT_TR="$(get_taskrun_for "${NS}" "${PR}" admit-signed-ceph)"
REJECT_TR="$(get_taskrun_for "${NS}" "${PR}" reject-unsigned-ceph)"
log::info "admit  TaskRun: ${ADMIT_TR:-<missing>}"
log::info "reject TaskRun: ${REJECT_TR:-<missing>}"

# ---- reject half (hard gate) -------------------------------------
if [[ -z "${REJECT_TR}" ]]; then
  log::fail "reject-unsigned-ceph TaskRun not found"
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi
REJECT_LOG="${E2E_ARTIFACTS}/kyverno-smoke-${REJECT_TR}.log"
tkn_ctx taskrun logs "${REJECT_TR}" -n "${NS}" --all >"${REJECT_LOG}" 2>&1 || true

REJECT_STATUS="$(kube_ctx -n "${NS}" get taskrun "${REJECT_TR}" \
                  -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')"
if [[ "${REJECT_STATUS}" != "True" ]]; then
  log::fail "reject-unsigned-ceph TaskRun did not Succeed (status=${REJECT_STATUS})"
  log::fail "  log: ${REJECT_LOG}"
  cat "${REJECT_LOG}" >&2
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi
if grep -Eqi 'cosign|signature|verify-ceph-image-signatures' "${REJECT_LOG}"; then
  log::pass "reject half: rejection mentions cosign/signature/policy"
else
  log::fail "reject half passed admission but log doesn't mention cosign/signature"
  log::fail "  (the Task says OK if Kyverno rejected with our wording — check log)"
  cat "${REJECT_LOG}" >&2
  exit 1
fi

# ---- admit half (gated by E2E_KYVERNO_STRICT_ADMIT) --------------
if [[ -z "${ADMIT_TR}" ]]; then
  log::warn "admit-signed-ceph TaskRun not found (likely never scheduled — see PipelineRun)"
  if [[ "${STRICT_ADMIT}" == "true" ]]; then
    capture_pipelinerun_artifacts "${NS}" "${PR}"
    exit 1
  fi
else
  ADMIT_LOG="${E2E_ARTIFACTS}/kyverno-smoke-${ADMIT_TR}.log"
  tkn_ctx taskrun logs "${ADMIT_TR}" -n "${NS}" --all >"${ADMIT_LOG}" 2>&1 || true
  ADMIT_STATUS="$(kube_ctx -n "${NS}" get taskrun "${ADMIT_TR}" \
                  -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')"
  if [[ "${ADMIT_STATUS}" == "True" ]] && grep -qF "OK: pod was admitted as expected" "${ADMIT_LOG}"; then
    log::pass "admit half: signed image was admitted"
  else
    log::warn "admit half failed (status=${ADMIT_STATUS}) — expected until issue #25 ships a real signed image"
    log::warn "  log: ${ADMIT_LOG}"
    if [[ "${STRICT_ADMIT}" == "true" ]]; then
      cat "${ADMIT_LOG}" >&2
      capture_pipelinerun_artifacts "${NS}" "${PR}"
      exit 1
    fi
  fi
fi

log::pass "assert-kyverno-smoke OK (reject half hard-gated; admit half tracked separately)"

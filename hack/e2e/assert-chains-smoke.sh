#!/usr/bin/env bash
# assert-chains-smoke.sh — run pipelines/chains-smoke-test.yaml and
# assert the full Chains -> cosign -> Rekor chain works end-to-end.
#
# Pass criteria:
#   1. PipelineRun succeeds.
#   2. The `sbom` TaskRun has both a chains.tekton.dev/payload-taskrun-*
#      annotation (the in-toto Statement) AND a sibling
#      chains.tekton.dev/signature-taskrun-* annotation.
#   3. The decoded Statement's predicateType is
#      https://slsa.dev/provenance/v1.
#   4. The Statement's subject digest equals the IMAGE_DIGEST Result
#      the sbom Task emitted.
#   5. `cosign verify-blob --key cosign.pub` against (signature,
#      Statement) returns Verified OK.
#   6. `rekor-cli search --public-key cosign.pub` returns at least one
#      log index.
#   7. The Statement contains a byproduct entry whose name ends
#      `/sbom-ARTIFACT_OUTPUTS`, with the documented shape
#      (uri starts workspace://, digest starts sha256:,
#       isBuildArtifact == "false").
#
# Prereqs in the cluster:
#   - Tekton Pipelines + Tekton Chains installed (make dev-up +
#     make dev-chains-up).
#   - tekton-chains/signing-secrets populated with cosign.{key,pub}.
#
# Local re-runs: this script is idempotent; each invocation creates a
# fresh PipelineRun and asserts only against that one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"

log::info "=== assert-chains-smoke ==="

require_cmd kubectl   "brew install kubectl"
require_cmd tkn       "brew install tektoncd-cli"
require_cmd cosign    "brew install cosign"
require_cmd rekor-cli "brew install rekor-cli"
require_cmd jq        "brew install jq"

# Pre-flight: cosign.pub must already exist in tekton-chains.
COSIGN_PUB="${E2E_ARTIFACTS}/cosign.pub"
fetch_cosign_pub "${COSIGN_PUB}"

# Apply the pipeline (idempotent).
kube_ctx apply -f "${E2E_REPO_ROOT}/pipelines/chains-smoke-test.yaml" >/dev/null

# Start the pipeline. The sbom Task needs a workspace; use emptyDir.
PR="$(start_pipelinerun "${NS}" chains-smoke-test \
        --workspace=name=sbom,emptyDir="")"
log::info "started PipelineRun: ${NS}/${PR}"

wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "chains-smoke-test PipelineRun did not Succeed"; exit 1; }

# Tekton Chains is asynchronous: the controller observes the completed
# TaskRun and writes its annotations *after* the TaskRun is Succeeded.
# Poll for the payload annotation on the sbom TaskRun for up to 120s.
SBOM_TR="$(get_taskrun_for "${NS}" "${PR}" sbom)"
if [[ -z "${SBOM_TR}" ]]; then
  log::fail "could not locate 'sbom' TaskRun under PipelineRun ${PR}"
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi
log::info "sbom TaskRun: ${SBOM_TR}"

log::info "waiting for Chains to annotate ${SBOM_TR} (up to 120s)..."
for i in $(seq 1 60); do
  if kube_ctx -n "${NS}" get taskrun "${SBOM_TR}" -o json \
      | jq -e '.metadata.annotations | keys[]? | select(startswith("chains.tekton.dev/payload-taskrun-"))' \
        >/dev/null 2>&1; then
    log::info "  payload annotation appeared after ~${i}*2s"
    break
  fi
  sleep 2
done

ATT="${E2E_ARTIFACTS}/chains-smoke.attestation.json"
SIG="${E2E_ARTIFACTS}/chains-smoke.sig"

decode_attestation "${NS}" "${SBOM_TR}" "${ATT}" \
  || { log::fail "no Chains attestation annotation on sbom TaskRun"; \
       capture_pipelinerun_artifacts "${NS}" "${PR}"; exit 1; }
decode_envelope "${NS}" "${SBOM_TR}" "${SIG}" \
  || { log::fail "no Chains signature annotation on sbom TaskRun"; \
       capture_pipelinerun_artifacts "${NS}" "${PR}"; exit 1; }

# --- assertion 3: predicateType -----------------------------------
PT="$(attestation_predicate_type "${ATT}")"
EXPECTED_PT="https://slsa.dev/provenance/v1"
if [[ "${PT}" == "${EXPECTED_PT}" ]]; then
  log::pass "predicateType = ${PT}"
else
  log::fail "predicateType is '${PT}', expected '${EXPECTED_PT}'"
  log::fail "  (Chains 0.26 slsa/v2alpha4 format must emit slsa/provenance/v1 predicateType)"
  exit 1
fi

# --- assertion 4: subject digest matches IMAGE_DIGEST Result -------
ATTEST_DIGEST="$(attestation_subject_digest "${ATT}")"
RESULT_DIGEST="$(get_taskrun_result "${NS}" "${SBOM_TR}" IMAGE_DIGEST)"
log::info "attestation subject digest: ${ATTEST_DIGEST}"
log::info "TaskRun IMAGE_DIGEST result: ${RESULT_DIGEST}"
if [[ "${ATTEST_DIGEST}" == "${RESULT_DIGEST}" ]]; then
  log::pass "attestation subject matches IMAGE_DIGEST Result"
else
  log::fail "subject digest != IMAGE_DIGEST"
  log::fail "  attestation: ${ATTEST_DIGEST}"
  log::fail "  result:      ${RESULT_DIGEST}"
  exit 1
fi

# --- assertion 5: cosign verify-blob -------------------------------
cosign_verify_envelope "${COSIGN_PUB}" "${SIG}" "${ATT}" \
  || { log::fail "cosign verify-blob failed"; exit 1; }

# --- assertion 6: Rekor log index ----------------------------------
rekor_search "${COSIGN_PUB}" \
  || { log::fail "Rekor search returned no entries"; exit 1; }

# --- assertion 7: SBOM byproduct in attestation --------------------
attestation_has_sbom_byproduct "${ATT}" \
  || { log::fail "attestation missing sbom-ARTIFACT_OUTPUTS byproduct"; exit 1; }
log::pass "attestation byproduct shape OK (uri/digest/isBuildArtifact)"

log::pass "assert-chains-smoke OK"

#!/usr/bin/env bash
# assert-compute-matrix-smoke.sh — run pipelines/compute-matrix-smoke-test.yaml
# and assert:
#
#   1. The PipelineRun reaches Succeeded (the in-cluster `assert-results`
#      Task does the real shape-checking; if it fails, the PipelineRun
#      fails).
#   2. As a defensive double-check from the test host, re-pull the
#      `matrix` / `cell-count` / `gating-count` Results off the
#      compute-matrix TaskRun and re-validate the JSON shape with jq.
#      This catches the (unlikely) case where Tekton itself drops/
#      truncates a Result string between TaskRun completion and our
#      consumer Task reading it.
#
# Prereqs:
#   - tasks/compute-matrix/task.yaml + pipelines/compute-matrix-smoke-test.yaml
#     installed.
#   - jq on PATH (used to re-parse the JSON array out of band).
#
# Mechanism for fetching the Result bytes out of the cluster:
#   compute-matrix emits the matrix as a Tekton Result, which lives in
#   the TaskRun's .status.results. No PVC needed — kubectl pulls the
#   bytes straight from the Tekton API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"

log::info "=== assert-compute-matrix-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"

# Apply the task + pipeline.
kube_ctx apply -f "${E2E_REPO_ROOT}/tasks/compute-matrix/task.yaml" >/dev/null
kube_ctx apply -f "${E2E_REPO_ROOT}/pipelines/compute-matrix-smoke-test.yaml" >/dev/null

# Source workspace is emptyDir — the seed Task writes matrix.yaml into
# it inside the PipelineRun and compute-matrix reads from it. No PVC
# bytes to extract afterwards; everything we care about is on the
# TaskRun's Result surface.
PR="$(start_pipelinerun "${NS}" compute-matrix-smoke-test \
        --workspace=name=source,emptyDir="")"
log::info "started PipelineRun: ${NS}/${PR}"

wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "compute-matrix-smoke-test PipelineRun did not Succeed"; exit 1; }

# ---------------------------------------------------------------------
# Defensive double-check: re-pull the Results off the compute-matrix
# TaskRun and re-validate from the test host. The in-cluster
# assert-results Task already validated this; we re-check from outside
# the cluster to catch any (unlikely) Result-truncation between the
# TaskRun and our consumer Task.
# ---------------------------------------------------------------------

TR="$(get_taskrun_for "${NS}" "${PR}" compute-matrix)"
if [[ -z "${TR}" ]]; then
  log::fail "could not find compute-matrix TaskRun for PipelineRun ${PR}"
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi
log::info "compute-matrix TaskRun: ${TR}"

MATRIX="$(get_taskrun_result "${NS}" "${TR}" matrix)"
CELL_COUNT="$(get_taskrun_result "${NS}" "${TR}" cell-count)"
GATING_COUNT="$(get_taskrun_result "${NS}" "${TR}" gating-count)"

log::info "matrix=${MATRIX}"
log::info "cell-count=${CELL_COUNT}"
log::info "gating-count=${GATING_COUNT}"

# Drop the Result bytes into the artefacts dir for easy debugging.
mkdir -p "${E2E_ARTIFACTS}/compute-matrix"
printf '%s\n' "${MATRIX}"       > "${E2E_ARTIFACTS}/compute-matrix/matrix.json"
printf '%s\n' "${CELL_COUNT}"   > "${E2E_ARTIFACTS}/compute-matrix/cell-count.txt"
printf '%s\n' "${GATING_COUNT}" > "${E2E_ARTIFACTS}/compute-matrix/gating-count.txt"

FAIL=0

# ---- matrix parses as a JSON array ----
if ! printf '%s' "${MATRIX}" | jq -e 'type == "array"' >/dev/null 2>&1; then
  log::fail "matrix Result does not parse as a JSON array"
  FAIL=1
fi

# ---- every entry has distro / arch / gating with correct types ----
if ! printf '%s' "${MATRIX}" \
    | jq -e 'all(.distro != null and (.distro|type) == "string"
                 and .arch != null and (.arch|type) == "string"
                 and .gating != null and (.gating|type) == "string"
                 and (.gating == "true" or .gating == "false"))' >/dev/null 2>&1; then
  log::fail "at least one matrix cell is missing distro/arch/gating, or gating is not the string 'true'/'false'"
  printf '%s\n' "${MATRIX}" | jq . >&2 || true
  FAIL=1
fi

# ---- cell-count == len(matrix), positive integer ----
ACTUAL_LEN="$(printf '%s' "${MATRIX}" | jq -r 'length')"
if [[ "${CELL_COUNT}" != "${ACTUAL_LEN}" ]]; then
  log::fail "cell-count=${CELL_COUNT} != len(matrix)=${ACTUAL_LEN}"
  FAIL=1
fi
if ! [[ "${CELL_COUNT}" =~ ^[0-9]+$ ]] || [[ "${CELL_COUNT}" -lt 1 ]]; then
  log::fail "cell-count=${CELL_COUNT} is not a positive integer"
  FAIL=1
fi

# ---- gating-count <= cell-count, matches jq-recomputed count ----
if ! [[ "${GATING_COUNT}" =~ ^[0-9]+$ ]]; then
  log::fail "gating-count=${GATING_COUNT} is not a non-negative integer"
  FAIL=1
fi
if [[ "${GATING_COUNT}" -gt "${CELL_COUNT}" ]]; then
  log::fail "gating-count=${GATING_COUNT} > cell-count=${CELL_COUNT}"
  FAIL=1
fi
JQ_GATING="$(printf '%s' "${MATRIX}" | jq -r '[.[] | select(.gating == "true")] | length')"
if [[ "${JQ_GATING}" != "${GATING_COUNT}" ]]; then
  log::fail "gating-count Result=${GATING_COUNT} != jq-recomputed=${JQ_GATING}"
  FAIL=1
fi

# ---- seeded values: 3 cells, 2 gating ----
if [[ "${CELL_COUNT}" != "3" ]]; then
  log::fail "expected 3 cells from synthetic seed, got ${CELL_COUNT}"
  FAIL=1
fi
if [[ "${GATING_COUNT}" != "2" ]]; then
  log::fail "expected 2 gating cells from synthetic seed, got ${GATING_COUNT}"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi

log::pass "assert-compute-matrix-smoke OK"

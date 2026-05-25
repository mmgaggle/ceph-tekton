#!/usr/bin/env bash
# assert-reproducibility-smoke.sh — run pipelines/reproducibility-check.yaml
# against the timestamps `broken` AND `fixed` example targets and assert:
#
#   - broken: pct_match < 100   (the __DATE__/__TIME__ macros embed wall
#                                time into the binary; two builds one
#                                second apart MUST diverge)
#   - fixed:  pct_match == 100  (with -D__DATE__/-D__TIME__ overrides
#                                driven by SOURCE_DATE_EPOCH, the two
#                                builds MUST be byte-identical)
#
# If broken comes back at 100 the harness is broken (something is
# masking the diff). If fixed comes back < 100 we have a real
# reproducibility regression. Either way it's a CI failure.
#
# Prereqs:
#   - tasks/reproducibility-check/task.yaml installed.
#   - pipelines/reproducibility-check.yaml installed.
#   - The `gcc:13-bookworm` builder image is reachable (Docker Hub).
#
# Notes on cost: each PipelineRun does two clones + two compile-and-link
# of a 4-line hello.c. <30s per run on the GHA ubuntu-latest 2-CPU
# runner including image pull. Two runs (broken + fixed) ~ 1min total.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"
BUILDER_IMAGE="${BUILDER_IMAGE:-docker.io/library/gcc:13-bookworm}"

# Shared params for both runs. Same source-repo (this repo on its
# current HEAD), same builder image. The two differ only in
# build-command + output-glob.
COMMON_PARAMS=(
  --param=source-repo=https://github.com/mmgaggle/ceph-tekton.git
  --param=source-ref=HEAD
  --param=builder-image="${BUILDER_IMAGE}"
  --workspace=name=scratch,emptyDir=""
  --workspace=name=s3-credentials,emptyDir=""
)

log::info "=== assert-reproducibility-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"

# Apply the task + pipeline.
kube_ctx apply -f "${E2E_REPO_ROOT}/tasks/reproducibility-check/task.yaml" >/dev/null
kube_ctx apply -f "${E2E_REPO_ROOT}/pipelines/reproducibility-check.yaml" >/dev/null

# ---- run #1: broken ---------------------------------------------------
log::info "--- broken target (expect pct_match < 100) ---"
BROKEN_PR="$(start_pipelinerun "${NS}" reproducibility-check \
    "${COMMON_PARAMS[@]}" \
    --param='build-command=cd tasks/reproducibility-check/examples/timestamps && make broken' \
    --param=output-glob=tasks/reproducibility-check/examples/timestamps/hello-broken)"
log::info "started PipelineRun: ${NS}/${BROKEN_PR}"

wait_pipelinerun_succeeded "${NS}" "${BROKEN_PR}" \
  || { log::fail "broken-target PipelineRun did not Succeed"; exit 1; }

BROKEN_PCT="$(kube_ctx -n "${NS}" get pipelinerun "${BROKEN_PR}" -o json \
              | jq -r '.status.results[]? | select(.name == "pct_match") | .value')"
log::info "broken pct_match = ${BROKEN_PCT}"

# Numeric compare with awk (the Result is a string like "37.500").
if awk -v p="${BROKEN_PCT}" 'BEGIN { exit !(p+0 < 100) }'; then
  log::pass "broken pct_match=${BROKEN_PCT} < 100 (as expected — wall-clock leaks)"
else
  log::fail "broken pct_match=${BROKEN_PCT} but expected < 100"
  log::fail "  (the harness is masking the diff — investigate)"
  capture_pipelinerun_artifacts "${NS}" "${BROKEN_PR}"
  exit 1
fi

# ---- run #2: fixed ----------------------------------------------------
log::info "--- fixed target (expect pct_match == 100) ---"
FIXED_PR="$(start_pipelinerun "${NS}" reproducibility-check \
    "${COMMON_PARAMS[@]}" \
    --param='build-command=cd tasks/reproducibility-check/examples/timestamps && make fixed' \
    --param=output-glob=tasks/reproducibility-check/examples/timestamps/hello-fixed)"
log::info "started PipelineRun: ${NS}/${FIXED_PR}"

wait_pipelinerun_succeeded "${NS}" "${FIXED_PR}" \
  || { log::fail "fixed-target PipelineRun did not Succeed"; exit 1; }

FIXED_PCT="$(kube_ctx -n "${NS}" get pipelinerun "${FIXED_PR}" -o json \
             | jq -r '.status.results[]? | select(.name == "pct_match") | .value')"
log::info "fixed pct_match = ${FIXED_PCT}"

# Accept 100, 100.0, 100.000 — all equivalent.
if awk -v p="${FIXED_PCT}" 'BEGIN { exit !(p+0 == 100) }'; then
  log::pass "fixed pct_match=${FIXED_PCT} == 100 (as expected — deterministic build)"
else
  log::fail "fixed pct_match=${FIXED_PCT} but expected 100"
  log::fail "  (reproducibility regression — the fixed target is no longer deterministic)"
  capture_pipelinerun_artifacts "${NS}" "${FIXED_PR}"
  exit 1
fi

log::pass "assert-reproducibility-smoke OK"

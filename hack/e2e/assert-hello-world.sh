#!/usr/bin/env bash
# assert-hello-world.sh — run pipelines/hello-world.yaml, assert
# the PipelineRun reaches Succeeded AND the TaskRun's pod logs
# contain the expected greeting substring.
#
# Pass criteria:
#   1. PipelineRun condition Succeeded=True within E2E_PIPELINERUN_TIMEOUT.
#   2. The `greet` TaskRun logs contain "hello, ceph — from ceph-tekton".
#
# Failure mode debugging hints:
#   - PipelineRun pending forever: tekton-pipelines controller not Ready;
#     `make dev-up` did not finish. `kubectl -n tekton-pipelines get pods`.
#   - Pod ImagePullBackOff on docker.io/library/busybox: Docker Hub rate
#     limit hit. Wait 5min or pre-load via `kind load docker-image`.
#   - Greeting not in logs: hello.yaml drifted; diff against git HEAD.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"
EXPECTED_SUBSTRING="hello, ceph — from ceph-tekton"

log::info "=== assert-hello-world ==="

# Apply the pipeline + task (idempotent). The dev-test target also
# applies it; we re-apply to make the e2e script self-contained when
# it's invoked outside the `make` graph.
kube_ctx apply -f "${E2E_REPO_ROOT}/pipelines/hello-world.yaml" >/dev/null

PR="$(start_pipelinerun "${NS}" hello-world --param=who=ceph)"
log::info "started PipelineRun: ${NS}/${PR}"

wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "hello-world PipelineRun did not Succeed"; exit 1; }

GREET_TR="$(get_taskrun_for "${NS}" "${PR}" greet)"
if [[ -z "${GREET_TR}" ]]; then
  log::fail "could not locate 'greet' TaskRun under PipelineRun ${PR}"
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi
log::info "greet TaskRun: ${GREET_TR}"

LOGFILE="${E2E_ARTIFACTS}/hello-world-${GREET_TR}.log"
tkn_ctx taskrun logs "${GREET_TR}" -n "${NS}" --all >"${LOGFILE}" 2>&1 || true

if grep -qF "${EXPECTED_SUBSTRING}" "${LOGFILE}"; then
  log::pass "greet log contains expected substring: '${EXPECTED_SUBSTRING}'"
else
  log::fail "greet log missing expected substring: '${EXPECTED_SUBSTRING}'"
  log::fail "  log captured at ${LOGFILE}"
  cat "${LOGFILE}" >&2
  exit 1
fi

log::pass "assert-hello-world OK"

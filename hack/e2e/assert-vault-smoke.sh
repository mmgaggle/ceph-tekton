#!/usr/bin/env bash
# assert-vault-smoke.sh — run pipelines/pipelines/vault-smoke-test.yaml and
# assert the terminal "OK: vault verified the signature — smoke test
# passed" log line appears.
#
# Pass criteria:
#   1. PipelineRun succeeds.
#   2. The `sign` TaskRun logs contain the substring
#      "OK: vault verified the signature".
#
# Prereqs:
#   - hack/dev-vault-up.sh has run (Vault + transit + k8s auth + the
#     vault-test namespace + ceph-test-signer SA).
#
# The pipeline MUST run in vault-test namespace as ceph-test-signer SA
# — that (ns, sa) pair is the one bound to the Vault role created by
# the bootstrap script. Anything else is rejected at vault login.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-vault-test}"
SA="${SA:-ceph-test-signer}"
EXPECTED_SUBSTRING="OK: vault verified the signature"

log::info "=== assert-vault-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"

# Verify the bootstrap-created resources exist before we try to run.
if ! kube_ctx get ns "${NS}" >/dev/null 2>&1; then
  log::fail "namespace ${NS} not found — did you run hack/dev-vault-up.sh?"
  exit 1
fi
if ! kube_ctx -n "${NS}" get serviceaccount "${SA}" >/dev/null 2>&1; then
  log::fail "ServiceAccount ${NS}/${SA} not found — did hack/dev-vault-up.sh succeed?"
  exit 1
fi
if ! kube_ctx -n vault get pod vault-0 >/dev/null 2>&1; then
  log::fail "vault-0 pod not found — Vault is not installed"
  exit 1
fi

# Apply the Task then the Pipeline (idempotent). Issue #68 split
# `pipelines/vault-smoke-test.yaml` (Task + Pipeline) into
# single-resource files under `pipelines/tasks/` and
# `pipelines/pipelines/` so PaC remote-resolution works. Apply order
# matters: Task before Pipeline.
#
# `-n "${NS}"` is required because the manifests don't pin a namespace;
# without it the Task + Pipeline land in the kubectl context's current
# namespace (usually `default`) while `tkn pipeline start` below looks
# in `${NS}` (vault-test) and fails with "Pipeline name vault-smoke-test
# does not exist".
kube_ctx -n "${NS}" apply -f "${E2E_REPO_ROOT}/pipelines/tasks/vault-sign-smoke.yaml" >/dev/null
kube_ctx -n "${NS}" apply -f "${E2E_REPO_ROOT}/pipelines/pipelines/vault-smoke-test.yaml" >/dev/null

PR="$(start_pipelinerun "${NS}" vault-smoke-test --serviceaccount="${SA}")"
log::info "started PipelineRun: ${NS}/${PR}"

wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "vault-smoke-test PipelineRun did not Succeed"; exit 1; }

SIGN_TR="$(get_taskrun_for "${NS}" "${PR}" sign)"
if [[ -z "${SIGN_TR}" ]]; then
  log::fail "could not locate 'sign' TaskRun under PipelineRun ${PR}"
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi

LOGFILE="${E2E_ARTIFACTS}/vault-smoke-${SIGN_TR}.log"
tkn_ctx taskrun logs "${SIGN_TR}" -n "${NS}" --all >"${LOGFILE}" 2>&1 || true

if grep -qF "${EXPECTED_SUBSTRING}" "${LOGFILE}"; then
  log::pass "vault sign log contains expected line: '${EXPECTED_SUBSTRING}'"
else
  log::fail "vault sign log missing expected line: '${EXPECTED_SUBSTRING}'"
  log::fail "  log captured at ${LOGFILE}"
  cat "${LOGFILE}" >&2
  exit 1
fi

log::pass "assert-vault-smoke OK"

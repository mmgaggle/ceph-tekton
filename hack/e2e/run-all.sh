#!/usr/bin/env bash
# run-all.sh — invoke every hack/e2e/assert-*.sh in order, fail-fast.
#
# Used by .github/workflows/e2e.yaml and by contributors who want to
# replay the full CI gauntlet against their dev cluster. Each
# assertion is its own script so devs can also cherry-pick (e.g.
# `hack/e2e/assert-chains-smoke.sh`) when iterating on a single
# component.
#
# Environment hooks:
#   E2E_KIND_CLUSTER       which kind cluster to target (default: e2e)
#   E2E_KUBE_CONTEXT       kubectl context name (default: kind-$E2E_KIND_CLUSTER)
#   E2E_ARTIFACTS          where to drop failure artefacts
#                          (default: $TMPDIR/ceph-tekton-e2e-artifacts)
#   E2E_PIPELINERUN_TIMEOUT  per-PipelineRun deadline (default 600s)
#   E2E_SKIP               space-separated list of assertion stems to skip
#                          (e.g. "vault-smoke kyverno-smoke" — useful when
#                          rerunning after a partial bootstrap)
#
# Exit codes:
#   0   all selected assertions passed
#   1   at least one assertion failed
#   2   tool prereqs not satisfied

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Ordered list. assert-hello-world runs first because it's the cheapest
# end-to-end sanity check that Tekton itself is alive — if it fails,
# everything after will too, so failing fast saves CI minutes.
#
# Chains smoke runs second so its attestations are written before the
# slower runs queue up. Vault is the most expensive (deep bootstrap
# + pod-pull cost) so we put it after Chains. Kyverno + reproducibility
# + generate-sbom are independent and ordered alphabetically for
# stable-ish "Nth-failure" diagnostics.
#
# zgw-posix-up runs immediately before vuln-scan-smoke because the
# vuln-scan-smoke-test pipeline will eventually point its
# `db-pointer-url` at the in-cluster zgw-posix Service instead of
# standing up its own busybox httpd Pod. Failing fast on zgw-posix
# saves us a multi-minute grype-DB stage that won't have anywhere
# to land.
#
# verify-image-signature-smoke runs after build-builder-image because
# both depend on the in-cluster registry:2 deployment in ns/e2e-registry.
# build-builder-image is the first to bring it up; running the verify
# smoke after means the registry image is already pulled and the
# verify script's idempotent re-apply is a no-op.
#
# verify-image-signature-keyless-smoke runs late in the list because
# it's the cheapest of the signature-verification smokes (no in-cluster
# registry, no host-side signing) but exercises the slowest external
# dependency (Rekor public-good instance, occasional 5xx). Putting it
# after the build-builder-image smoke means failures are unambiguously
# attributable to the keyless / Rekor path rather than to cluster
# bring-up.
#
# cloudevents-sink runs immediately after zgw-posix-up because the
# sink writes to a bucket on zgw-posix; failing fast on zgw-posix
# already happened, and the sink readiness probe HEADs the bucket so
# slotting cloudevents-sink right after zgw-posix-up keeps the
# "S3-dependent" stripe of assertions contiguous in the log.
ASSERTIONS=(
  hello-world
  chains-smoke
  vault-smoke
  kyverno-smoke
  reproducibility-smoke
  generate-sbom-smoke
  compute-matrix-smoke
  zgw-posix-up
  cloudevents-sink
  vuln-scan-smoke
  build-builder-image
  verify-image-signature-smoke
  verify-image-signature-keyless-smoke
)

SKIP="${E2E_SKIP:-}"
should_skip() {
  local name="$1"
  for s in ${SKIP}; do
    if [[ "${s}" == "${name}" ]]; then return 0; fi
  done
  return 1
}

# Tool prereqs (top-level). Per-script require_cmd handles per-script
# additions (e.g. cosign/rekor-cli for chains-smoke). Here we check
# what's needed by ANY assertion so the workflow fails before spinning
# up the cluster if a tool is missing.
require_cmd kubectl   "https://kubernetes.io/docs/tasks/tools/" || exit 2
require_cmd tkn       "https://tekton.dev/docs/cli/"            || exit 2
require_cmd jq        "https://stedolan.github.io/jq/"          || exit 2

log::info "==================================================="
log::info "ceph-tekton e2e harness"
log::info "  kind cluster:  ${E2E_KIND_CLUSTER}"
log::info "  kube context:  ${E2E_KUBE_CONTEXT}"
log::info "  artefacts dir: ${E2E_ARTIFACTS}"
log::info "  skip list:     ${SKIP:-<none>}"
log::info "==================================================="

# Sanity check the cluster is reachable.
if ! kube_ctx version >/dev/null 2>&1; then
  log::fail "kubectl --context=${E2E_KUBE_CONTEXT} cannot reach the API server"
  log::fail "  (is the kind cluster up? \`kind get clusters\`)"
  exit 2
fi

# Run!
FAILED=()
for name in "${ASSERTIONS[@]}"; do
  if should_skip "${name}"; then
    log::warn "SKIP assert-${name}"
    continue
  fi
  script="${SCRIPT_DIR}/assert-${name}.sh"
  if [[ ! -f "${script}" ]]; then
    log::fail "assertion script not found: ${script}"
    FAILED+=("${name}")
    continue
  fi
  log::info ""
  log::info "==> assert-${name}"
  log::info ""
  # Invoke via `bash` rather than `exec` so the exec bit isn't required
  # — keeps the harness runnable straight after a fresh `git clone`
  # before anyone has chmod'd anything.
  if bash "${script}"; then
    log::pass "assert-${name} PASSED"
  else
    log::fail "assert-${name} FAILED"
    FAILED+=("${name}")
    # Fail fast unless E2E_CONTINUE_ON_FAIL=true.
    if [[ "${E2E_CONTINUE_ON_FAIL:-false}" != "true" ]]; then
      capture_cluster_state
      log::fail ""
      log::fail "stopping at first failure. Set E2E_CONTINUE_ON_FAIL=true"
      log::fail "to run every remaining assertion regardless."
      exit 1
    fi
  fi
done

if [[ "${#FAILED[@]}" -gt 0 ]]; then
  capture_cluster_state
  log::fail "FAILED assertions: ${FAILED[*]}"
  exit 1
fi

log::pass ""
log::pass "all assertions passed"
log::pass ""

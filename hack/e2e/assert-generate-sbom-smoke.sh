#!/usr/bin/env bash
# assert-generate-sbom-smoke.sh — run pipelines/sbom-pkg-smoke-test.yaml
# and assert:
#
#   1. The PipelineRun reaches Succeeded.
#   2. The CycloneDX-JSON SBOM file(s) the generate-sbom Task produced
#      parse with `syft scan cyclonedx-json:<file>` (exit 0).
#
# DELIBERATELY OUT OF SCOPE FOR THIS ASSERTION:
#   - "SBOM landed in the Chains attestation". The current Chains 0.26
#     grammar ignores the contract-level SBOM_NAMES / SBOM_COUNT /
#     SBOM_MEDIATYPE Results that generate-sbom emits — see the warning
#     box at the top of docs/provenance.md ("Per-build package SBOMs")
#     and issue #55. The rewrite to use `cosign attach sbom` is tracked
#     separately. This smoke ONLY proves the SBOM FILE is correctly
#     produced by syft inside the Task.
#
# Prereqs:
#   - tasks/generate-sbom/task.yaml installed.
#   - syft binary on PATH (used to round-trip the SBOM file).
#
# Mechanism for fetching the SBOM file out of the cluster:
#   The generate-sbom Task writes one <basename>.cdx.json per artifact
#   into the `sboms` workspace. We mount that workspace as an emptyDir,
#   so the only way to get the bytes out post-run is to look at the
#   TaskRun's pod and grab them. We use `kubectl debug` against the
#   completed pod's node, but easier: we drop a tiny "exfil" Task into
#   the pipeline via a one-shot Pod that re-mounts the same emptyDir.
#
# Simpler approach used here: re-run a tiny Task that scans the
# artifacts workspace WITHIN the cluster and emits the SBOM bytes as
# a Tekton Result (which we can read out via kubectl). That keeps the
# assertion hermetic and avoids needing kubectl-debug or copying out
# of an ephemeral pod.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"

log::info "=== assert-generate-sbom-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"
require_cmd syft    "brew install syft"

# Apply the task + pipeline.
kube_ctx apply -f "${E2E_REPO_ROOT}/tasks/generate-sbom/task.yaml" >/dev/null
kube_ctx apply -f "${E2E_REPO_ROOT}/pipelines/sbom-pkg-smoke-test.yaml" >/dev/null

# Use a NAMED PVC for the sboms workspace so we can re-mount it in a
# follow-up debug Pod and read the SBOM bytes out. The artifacts
# workspace can stay an emptyDir — it's only consumed within the
# PipelineRun and we don't need its bytes after the fact.
PVC_NAME="e2e-sbom-pvc-$(date +%s)"
kube_ctx -n "${NS}" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Mi
EOF
cleanup_pvc() {
  kube_ctx -n "${NS}" delete pvc "${PVC_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kube_ctx -n "${NS}" delete pod  "exfil-${PVC_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup_pvc EXIT

PR="$(start_pipelinerun "${NS}" sbom-pkg-smoke-test \
        --workspace=name=artifacts,emptyDir="" \
        --workspace=name=sboms,claimName="${PVC_NAME}")"
log::info "started PipelineRun: ${NS}/${PR}"

wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "sbom-pkg-smoke-test PipelineRun did not Succeed"; exit 1; }

# Spin up a sidecar pod that mounts the same PVC and copies the SBOM
# files into stdout / artefacts dir.
log::info "extracting SBOM bytes via sidecar pod..."
kube_ctx -n "${NS}" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: exfil-${PVC_NAME}
spec:
  restartPolicy: Never
  containers:
    - name: exfil
      image: docker.io/library/busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          set -e
          echo "=== sboms workspace contents ==="
          ls -la /sboms
          for f in /sboms/*.cdx.json; do
            [ -f "\$f" ] || continue
            echo "=== BEGIN \$f ==="
            cat "\$f"
            echo "=== END \$f ==="
          done
          sleep 3600
      volumeMounts:
        - name: sboms
          mountPath: /sboms
  volumes:
    - name: sboms
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF

kube_ctx -n "${NS}" wait --for=condition=Ready pod "exfil-${PVC_NAME}" --timeout=120s >/dev/null

# Pull the SBOM file list.
SBOM_NAMES="$(kube_ctx -n "${NS}" exec "exfil-${PVC_NAME}" -c exfil -- \
              sh -c "ls /sboms/*.cdx.json 2>/dev/null" || true)"
if [[ -z "${SBOM_NAMES}" ]]; then
  log::fail "no *.cdx.json files in the sboms workspace"
  kube_ctx -n "${NS}" exec "exfil-${PVC_NAME}" -c exfil -- ls -la /sboms >&2 || true
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi

# Pull each one out and round-trip it through `syft scan cyclonedx-json:`.
SBOM_DIR="${E2E_ARTIFACTS}/sboms"
mkdir -p "${SBOM_DIR}"
FAIL=0
for path in ${SBOM_NAMES}; do
  base="$(basename "${path}")"
  local_path="${SBOM_DIR}/${base}"
  kube_ctx -n "${NS}" exec "exfil-${PVC_NAME}" -c exfil -- cat "${path}" >"${local_path}"
  size="$(wc -c <"${local_path}")"
  log::info "extracted ${base} (${size} bytes)"

  if syft scan "cyclonedx-json:${local_path}" -o table >/dev/null 2>"${SBOM_DIR}/${base}.syft.err"; then
    log::pass "syft round-trips ${base}"
  else
    log::fail "syft refused ${base} — see ${SBOM_DIR}/${base}.syft.err"
    cat "${SBOM_DIR}/${base}.syft.err" >&2
    FAIL=1
  fi
done

if [[ "${FAIL}" -ne 0 ]]; then
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi

log::pass "assert-generate-sbom-smoke OK"

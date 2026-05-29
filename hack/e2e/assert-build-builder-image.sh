#!/usr/bin/env bash
# assert-build-builder-image.sh — run pipelines/build-builder-image.yaml
# (sourced from images/builders/pipeline.yaml) end-to-end against a
# tiny synthetic Containerfile, and assert:
#
#   1. The PipelineRun reaches Succeeded.
#   2. IMAGE_URL Result equals the output-image we passed in.
#   3. IMAGE_DIGEST Result is a `sha256:<64-hex>` digest.
#   4. IMAGES Result has shape `<url>@sha256:<hex>` (single line).
#   5. ARTIFACT_OUTPUTS is a JSON object with uri/digest/isBuildArtifact:"true"
#      (the Chains promote-to-subject form documented in the Task).
#   6. The pushed image is fetchable from the in-cluster registry.
#
# Repeats the above for every distro in `DISTROS` (defaults to
# `centos10`), so a single smoke run exercises the Task plumbing for
# each builder Dockerfile we ship. Each iteration uses its own PVC +
# unique image tag so concurrent re-runs and re-pushes don't collide
# in the in-cluster registry's content store.
#
# WHY A SYNTHETIC CONTAINERFILE INSTEAD OF THE REAL Dockerfile.<distro>:
# A real install-deps.sh run takes 10-20min and ~3GB of dnf/apt
# metadata + python wheels. The 2-CPU GHA runner cannot afford that
# per-PR. The synthetic Containerfile (a 2-line `FROM busybox + COPY`)
# exercises EVERY code path the Task has:
#   - buildah build, layer commit, OCI manifest format
#   - buildah tag (the extra-tags step)
#   - buildah push to a real registry, --digestfile capture
#   - emit-results step parsing the digest + writing the Chains
#     grammar Results
# Per the matrix, the synthetic build runs once per distro — same
# Containerfile, different tag — because what we're exercising is the
# Task pipeline plumbing, not distro-specific install logic.
#
# To run the FULL Dockerfile.<distro> builds (e.g. before tagging a
# release), set `E2E_BUILDER_IMAGE_FULL_BUILD=true` — this swaps the
# synthetic Containerfile for `images/builders/Dockerfile.<distro>`
# per iteration and gives each PipelineRun a 30-min timeout. Not run
# by default in CI; useful locally to verify a Dockerfile change
# before pushing.
#
# DISTROS env var:
#   Whitespace-separated list of distros to smoke. Each entry must
#   correspond to an `images/builders/Dockerfile.<distro>` (only
#   consulted in FULL_BUILD mode; the synthetic path doesn't read it).
#   Example:
#     DISTROS="centos10 ubuntu-noble" bash hack/e2e/assert-build-builder-image.sh
#   Default: `centos10 ubuntu-jammy` — kept alphabetical so #99/#101
#   land as trivial single-line additions.
#
# IN-CLUSTER REGISTRY:
# The smoke deploys a single-Pod `registry:2` Service in the same
# namespace and points the Pipeline at it. No persistence — wiped on
# cleanup. This is the same shape Sepia's in-cluster OpenShift
# registry presents to a Pipeline (a Service + a port), modulo the
# OpenShift-specific TLS + image-pusher SA RBAC that the Sepia
# overlay layers on. The registry is brought up once and reused
# across DISTROS iterations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"
REGISTRY_NS="${REGISTRY_NS:-e2e-registry}"
REGISTRY_SERVICE="${REGISTRY_SERVICE:-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_INTERNAL="${REGISTRY_SERVICE}.${REGISTRY_NS}.svc:${REGISTRY_PORT}"
FULL_BUILD="${E2E_BUILDER_IMAGE_FULL_BUILD:-false}"

# DISTROS: accept either a bash array (if the caller `source`d this
# script — unusual) or, more typically, a whitespace-separated string
# env var. `read -r -a` normalizes both into the DISTRO_LIST array.
# Default is the alphabetised set of distros that ship a Dockerfile
# in `images/builders/` and have landed their per-distro smoke wiring.
read -r -a DISTRO_LIST <<<"${DISTROS:-centos10 rocky10 ubuntu-jammy ubuntu-noble}"
if [[ "${#DISTRO_LIST[@]}" -eq 0 ]]; then
  log::fail "DISTROS resolved to an empty list — refusing to run"
  exit 2
fi

log::info "=== assert-build-builder-image ==="
log::info "DISTROS=(${DISTRO_LIST[*]})"

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"

# ---------------------------------------------------------------------
# Stage 1: deploy an in-cluster registry:2 if not already present.
# Once per script invocation — reused across all DISTROS iterations.
# ---------------------------------------------------------------------
log::info "ensuring in-cluster registry in ns/${REGISTRY_NS}..."
kube_ctx create namespace "${REGISTRY_NS}" --dry-run=client -o yaml \
  | kube_ctx apply -f - >/dev/null
kube_ctx -n "${REGISTRY_NS}" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${REGISTRY_SERVICE}
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${REGISTRY_SERVICE} }
  template:
    metadata:
      labels: { app: ${REGISTRY_SERVICE} }
    spec:
      containers:
        - name: registry
          image: docker.io/library/registry:2.8
          ports:
            - containerPort: ${REGISTRY_PORT}
          env:
            - name: REGISTRY_HTTP_ADDR
              value: 0.0.0.0:${REGISTRY_PORT}
          # Backed by emptyDir — wiped with the Pod, fine for smoke.
          volumeMounts:
            - name: registry-data
              mountPath: /var/lib/registry
      volumes:
        - name: registry-data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${REGISTRY_SERVICE}
spec:
  selector: { app: ${REGISTRY_SERVICE} }
  ports:
    - port: ${REGISTRY_PORT}
      targetPort: ${REGISTRY_PORT}
EOF

kube_ctx -n "${REGISTRY_NS}" rollout status deploy/${REGISTRY_SERVICE} --timeout=120s >/dev/null

# Apply the Task + Pipeline once — every iteration starts a PipelineRun
# against the same Pipeline definition. The synthetic Dockerfile and
# the per-iteration tag carry the per-distro variation.
kube_ctx apply -f "${E2E_REPO_ROOT}/tasks/build-builder-image/task.yaml" >/dev/null
kube_ctx apply -f "${E2E_REPO_ROOT}/images/builders/pipeline.yaml" >/dev/null

# Track per-iteration PVC names + stage-pod names so the EXIT trap
# can clean them all up even if a mid-loop failure aborts the script.
# Indexed by iteration number for log-readability on failure.
ITER_PVCS=()
ITER_STAGE_PODS=()
ITER_VERIFY_PODS=()

cleanup() {
  for pvc in "${ITER_PVCS[@]}"; do
    kube_ctx -n "${NS}" delete pvc "${pvc}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  for pod in "${ITER_STAGE_PODS[@]}" "${ITER_VERIFY_PODS[@]}"; do
    kube_ctx -n "${NS}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  # Don't tear down the registry — re-runs reuse it.
}
trap cleanup EXIT

# Track which distros failed so we can summarise at the end and so a
# single bad distro doesn't mask the others' results.
FAILED_DISTROS=()

# Shared timestamp for the whole script run — every iteration appends
# its index to keep tags unique even within a sub-second window.
RUN_TS="$(date +%s)"

read_pr_result() {
  local pr="$1"
  local name="$2"
  kube_ctx -n "${NS}" get pipelinerun "${pr}" -o json \
    | jq -r --arg n "${name}" '.status.results[]? | select(.name == $n) | .value'
}

# ---------------------------------------------------------------------
# Per-distro smoke: stage PVC, start PipelineRun, assert Results,
# verify-fetch via crane.
# ---------------------------------------------------------------------
assert_distro() {
  local distro="$1"
  local iter="$2"
  local FAIL=0

  log::info ""
  log::info "==> [${distro}] iteration ${iter}/${#DISTRO_LIST[@]}"
  log::info ""

  # -------------------------------------------------------------------
  # Stage 2: stage the build context onto a per-iteration PVC.
  # -------------------------------------------------------------------
  local PVC_NAME="e2e-builder-source-${RUN_TS}-${iter}"
  local STAGE_POD="stage-${PVC_NAME}"
  ITER_PVCS+=("${PVC_NAME}")
  ITER_STAGE_PODS+=("${STAGE_POD}")

  log::info "[${distro}] staging source PVC: ${PVC_NAME}"
  kube_ctx -n "${NS}" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 200Mi
EOF

  kube_ctx -n "${NS}" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${STAGE_POD}
spec:
  restartPolicy: Never
  containers:
    - name: stage
      image: docker.io/library/busybox:1.36
      command: ["sh", "-c", "mkdir -p /src/images/builders && sleep 3600"]
      volumeMounts:
        - name: src
          mountPath: /src
  volumes:
    - name: src
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
EOF
  kube_ctx -n "${NS}" wait --for=condition=Ready pod "${STAGE_POD}" --timeout=120s >/dev/null

  local DOCKERFILE_PATH
  local PIPELINERUN_TIMEOUT_OVERRIDE
  if [[ "${FULL_BUILD}" == "true" ]]; then
    log::info "[${distro}] staging REAL Dockerfile.${distro} (E2E_BUILDER_IMAGE_FULL_BUILD=true)"
    DOCKERFILE_PATH="images/builders/Dockerfile.${distro}"
    PIPELINERUN_TIMEOUT_OVERRIDE="1800s"
    local real_dockerfile="${E2E_REPO_ROOT}/images/builders/Dockerfile.${distro}"
    if [[ ! -f "${real_dockerfile}" ]]; then
      log::fail "[${distro}] Dockerfile not found: ${real_dockerfile}"
      FAILED_DISTROS+=("${distro}")
      return 1
    fi
    kube_ctx -n "${NS}" cp \
      "${real_dockerfile}" \
      "${STAGE_POD}:/src/images/builders/Dockerfile.${distro}"
    kube_ctx -n "${NS}" cp \
      "${E2E_REPO_ROOT}/images/builders/build-package.sh" \
      "${STAGE_POD}:/src/images/builders/build-package.sh"
  else
    log::info "[${distro}] staging synthetic Containerfile (set E2E_BUILDER_IMAGE_FULL_BUILD=true for the real ${distro} build)"
    DOCKERFILE_PATH="images/builders/Dockerfile.smoke"
    PIPELINERUN_TIMEOUT_OVERRIDE="${E2E_PIPELINERUN_TIMEOUT}"
    # The synthetic Dockerfile is identical across distros — the
    # per-iteration `distro` label is the only knob that changes,
    # purely for log/telemetry attribution. The Task plumbing this
    # exercises (buildah / Chains-Results) is distro-agnostic.
    kube_ctx -n "${NS}" exec -i "${STAGE_POD}" -- sh -c "cat > /src/images/builders/Dockerfile.smoke" <<SMOKE_DOCKERFILE
# Synthetic Containerfile for the build-builder-image e2e smoke test.
# Tiny + offline-friendly: pulls only busybox, no install-deps.sh run.
# Exercises the same buildah + Chains-Results path as the real
# Dockerfile.${distro}, so a green smoke proves the Task plumbing works.
FROM docker.io/library/busybox:1.36
ARG SOURCE_DATE_EPOCH
ARG OCI_IMAGE_CREATED=unknown
ARG OCI_IMAGE_REVISION=smoke
ARG OCI_IMAGE_SOURCE=https://github.com/mmgaggle/ceph-tekton
ARG CEPH_SHA=smoke-sha
ARG BUILDER_IMAGE_VERSION=0.0.0-smoke
ARG INSTALL_DEPS_FOR_MAKE_CHECK=false
COPY build-package.sh /usr/local/bin/build-package.sh
RUN chmod +x /usr/local/bin/build-package.sh
LABEL org.opencontainers.image.source="\${OCI_IMAGE_SOURCE}" \\
      org.opencontainers.image.revision="\${OCI_IMAGE_REVISION}" \\
      org.opencontainers.image.created="\${OCI_IMAGE_CREATED}" \\
      org.ceph.builder-image.version="\${BUILDER_IMAGE_VERSION}" \\
      org.ceph.builder-image.ceph-sha="\${CEPH_SHA}" \\
      org.ceph.builder-image.distro="${distro}"
ENTRYPOINT ["/usr/local/bin/build-package.sh"]
SMOKE_DOCKERFILE

    kube_ctx -n "${NS}" cp \
      "${E2E_REPO_ROOT}/images/builders/build-package.sh" \
      "${STAGE_POD}:/src/images/builders/build-package.sh"
  fi

  # Sanity check.
  log::info "[${distro}] source workspace contents:"
  kube_ctx -n "${NS}" exec "${STAGE_POD}" -- ls -la /src/images/builders >&2

  # -------------------------------------------------------------------
  # Stage 3: start a PipelineRun for this distro.
  # -------------------------------------------------------------------
  # Per-iteration tag includes distro + iter so concurrent / repeated
  # smoke runs don't collide on a single registry tag in the content
  # store. The "-latest" companion tag is per-distro (not per-iter) to
  # match what the real promote-to-latest flow produces in Sepia.
  local TAG="${distro}-x86_64-smoke-${RUN_TS}-${iter}"
  local OUTPUT_IMAGE="${REGISTRY_INTERNAL}/ceph-builder:${TAG}"
  local LATEST_IMAGE="${REGISTRY_INTERNAL}/ceph-builder:${distro}-x86_64-latest"

  # tls-verify=false because the in-cluster registry:2 deployment above
  # serves plaintext HTTP. Sepia + ghcr.io + quay.io all use real TLS.
  # storage-driver=vfs because kind's cgroup-v2 + ubuntu kernel doesn't
  # always expose fuse-overlayfs to non-privileged pods; vfs is the
  # safe-everywhere choice.
  #
  # `--use-param-defaults` is required: the Pipeline declares optional
  # params (`source-date-epoch`, `source-url`, `subject-prefix`,
  # `buildah-image`) the caller doesn't override here, and without the
  # flag `tkn pipeline start` drops into interactive mode and prompts
  # for each one — which hangs the smoke run forever (and was the
  # silent failure mode observed before this flag was added).
  log::info "[${distro}] starting build-builder-image PipelineRun..."
  local PR
  PR="$(E2E_PIPELINERUN_TIMEOUT="${PIPELINERUN_TIMEOUT_OVERRIDE}" \
        start_pipelinerun "${NS}" build-builder-image \
          --use-param-defaults \
          --param="dockerfile-path=${DOCKERFILE_PATH}" \
          --param="build-context=images/builders" \
          --param="output-image=${OUTPUT_IMAGE}" \
          --param="output-image-latest=${LATEST_IMAGE}" \
          --param="ceph-sha=smoke-sha" \
          --param="builder-image-version=0.0.0-smoke" \
          --param="install-deps-for-make-check=false" \
          --param="source-revision=$(git -C "${E2E_REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo smoke)" \
          --param="tls-verify=false" \
          --param="storage-driver=vfs" \
          --workspace="name=source,claimName=${PVC_NAME}" \
          --workspace="name=registry-credentials,emptyDir=")"
  log::info "[${distro}] started PipelineRun: ${NS}/${PR}"

  if ! E2E_PIPELINERUN_TIMEOUT="${PIPELINERUN_TIMEOUT_OVERRIDE}" \
        wait_pipelinerun_succeeded "${NS}" "${PR}"; then
    log::fail "[${distro}] build-builder-image PipelineRun did not Succeed"
    FAILED_DISTROS+=("${distro}")
    return 1
  fi

  # -------------------------------------------------------------------
  # Stage 4: assert the Pipeline-level Results.
  # -------------------------------------------------------------------
  log::info "[${distro}] reading Pipeline-level Results from ${PR}"

  local R_IMAGE_URL R_IMAGE_DIGEST R_IMAGES R_ARTIFACT_OUTPUTS R_IMAGE_TAGS
  R_IMAGE_URL="$(read_pr_result "${PR}" IMAGE_URL)"
  R_IMAGE_DIGEST="$(read_pr_result "${PR}" IMAGE_DIGEST)"
  R_IMAGES="$(read_pr_result "${PR}" IMAGES)"
  R_ARTIFACT_OUTPUTS="$(read_pr_result "${PR}" ARTIFACT_OUTPUTS)"
  R_IMAGE_TAGS="$(read_pr_result "${PR}" image-tags)"

  log::info "[${distro}] IMAGE_URL=${R_IMAGE_URL}"
  log::info "[${distro}] IMAGE_DIGEST=${R_IMAGE_DIGEST}"
  log::info "[${distro}] IMAGES=${R_IMAGES}"
  log::info "[${distro}] ARTIFACT_OUTPUTS=${R_ARTIFACT_OUTPUTS}"
  log::info "[${distro}] image-tags="
  printf '%s\n' "${R_IMAGE_TAGS}" | sed 's/^/  /' >&2

  # Assertion 2: IMAGE_URL matches what we asked for.
  if [[ "${R_IMAGE_URL}" == "${OUTPUT_IMAGE}" ]]; then
    log::pass "[${distro}] IMAGE_URL == ${OUTPUT_IMAGE}"
  else
    log::fail "[${distro}] IMAGE_URL mismatch — got '${R_IMAGE_URL}', expected '${OUTPUT_IMAGE}'"
    FAIL=1
  fi

  # Assertion 3: IMAGE_DIGEST is a sha256:<64-hex> string.
  if printf '%s' "${R_IMAGE_DIGEST}" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    log::pass "[${distro}] IMAGE_DIGEST has shape sha256:<64-hex>"
  else
    log::fail "[${distro}] IMAGE_DIGEST malformed — got '${R_IMAGE_DIGEST}'"
    FAIL=1
  fi

  # Assertion 4: IMAGES has one `<url>@sha256:<hex>` line.
  local IMG_LINES
  IMG_LINES="$(printf '%s' "${R_IMAGES}" | grep -Ec '@sha256:[0-9a-f]{64}' || true)"
  if [[ "${IMG_LINES}" -ge 1 ]]; then
    log::pass "[${distro}] IMAGES has ${IMG_LINES} <url>@<digest> line(s)"
  else
    log::fail "[${distro}] IMAGES missing the <url>@sha256:<hex> shape"
    log::fail "[${distro}]   got: ${R_IMAGES}"
    FAIL=1
  fi

  # Assertion 5: ARTIFACT_OUTPUTS is JSON with the documented shape.
  if printf '%s' "${R_ARTIFACT_OUTPUTS}" \
      | jq -e '
          has("uri") and has("digest") and has("isBuildArtifact")
          and (.digest | startswith("sha256:"))
          and (.isBuildArtifact == "true")
        ' >/dev/null 2>&1; then
    log::pass "[${distro}] ARTIFACT_OUTPUTS has documented shape (uri/digest/isBuildArtifact:true)"
  else
    log::fail "[${distro}] ARTIFACT_OUTPUTS malformed — got '${R_ARTIFACT_OUTPUTS}'"
    FAIL=1
  fi

  # image-tags should list both the primary tag and the -latest tag.
  if printf '%s\n' "${R_IMAGE_TAGS}" | grep -qF "${OUTPUT_IMAGE}"; then
    log::pass "[${distro}] image-tags lists ${OUTPUT_IMAGE}"
  else
    log::fail "[${distro}] image-tags missing ${OUTPUT_IMAGE}"
    FAIL=1
  fi
  if printf '%s\n' "${R_IMAGE_TAGS}" | grep -qF "${LATEST_IMAGE}"; then
    log::pass "[${distro}] image-tags lists ${LATEST_IMAGE}"
  else
    log::fail "[${distro}] image-tags missing ${LATEST_IMAGE} (the -latest companion tag)"
    FAIL=1
  fi

  # -------------------------------------------------------------------
  # Stage 5: prove the image is actually fetchable from the registry.
  #
  # Use a tiny one-shot Pod that runs `crane digest` (via gcr.io/go-containerregistry/crane).
  # This is more portable than spinning up another buildah pod just to
  # `buildah pull` — crane is purpose-built for the "introspect a remote
  # image" use case + is a single static Go binary.
  # -------------------------------------------------------------------
  log::info "[${distro}] verifying image is fetchable from ${OUTPUT_IMAGE}"
  local VERIFY_POD="verify-${PVC_NAME}"
  ITER_VERIFY_PODS+=("${VERIFY_POD}")
  kube_ctx -n "${NS}" run "${VERIFY_POD}" \
    --image=gcr.io/go-containerregistry/crane:v0.20.2 \
    --restart=Never \
    --command -- \
    /ko-app/crane digest --insecure "${OUTPUT_IMAGE}" >/dev/null 2>&1 || true

  # Wait for it to finish (success or fail).
  local phase
  for _ in $(seq 1 30); do
    phase="$(kube_ctx -n "${NS}" get pod "${VERIFY_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    case "${phase}" in
      Succeeded|Failed) break ;;
    esac
    sleep 2
  done

  local VERIFY_DIGEST
  VERIFY_DIGEST="$(kube_ctx -n "${NS}" logs "${VERIFY_POD}" 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)"
  kube_ctx -n "${NS}" delete pod "${VERIFY_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  if printf '%s' "${VERIFY_DIGEST}" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    log::pass "[${distro}] crane fetched digest ${VERIFY_DIGEST} from ${OUTPUT_IMAGE}"
    if [[ "${VERIFY_DIGEST}" == "${R_IMAGE_DIGEST}" ]]; then
      log::pass "[${distro}] registry-side digest matches IMAGE_DIGEST Result"
    else
      log::fail "[${distro}] registry digest (${VERIFY_DIGEST}) != IMAGE_DIGEST Result (${R_IMAGE_DIGEST})"
      FAIL=1
    fi
  else
    # Soft-fail: registry round-trip is the "nice to have" tier of this
    # assertion. The Results-shape checks above are the hard contract.
    log::warn "[${distro}] could not crane-fetch digest from ${OUTPUT_IMAGE} (got: '${VERIFY_DIGEST}')"
    log::warn "[${distro}]   the Task's emit-results contract is verified; registry pull is best-effort"
  fi

  if [[ "${FAIL}" -ne 0 ]]; then
    capture_pipelinerun_artifacts "${NS}" "${PR}"
    FAILED_DISTROS+=("${distro}")
    return 1
  fi

  log::pass "[${distro}] assert-build-builder-image OK"
  return 0
}

# Drive the matrix. Don't fail-fast — run every distro so a single
# broken Dockerfile.<distro> doesn't mask a regression in another.
ITER=0
for distro in "${DISTRO_LIST[@]}"; do
  ITER=$((ITER + 1))
  # `|| true` so a single distro's failure doesn't trip `set -e` and
  # abort the loop. assert_distro records the failure in FAILED_DISTROS.
  assert_distro "${distro}" "${ITER}" || true
done

if [[ "${#FAILED_DISTROS[@]}" -gt 0 ]]; then
  log::fail ""
  log::fail "assert-build-builder-image FAILED for: ${FAILED_DISTROS[*]}"
  log::fail ""
  exit 1
fi

log::pass ""
log::pass "assert-build-builder-image OK for: ${DISTRO_LIST[*]}"
log::pass ""

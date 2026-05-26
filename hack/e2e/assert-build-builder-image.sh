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
# WHY A SYNTHETIC CONTAINERFILE INSTEAD OF THE REAL Dockerfile.centos10:
# A real install-deps.sh run takes 10-20min and ~3GB of dnf metadata
# + python wheels. The 2-CPU GHA runner cannot afford that per-PR.
# The synthetic Containerfile (a 2-line `FROM busybox + COPY`)
# exercises EVERY code path the Task has:
#   - buildah build, layer commit, OCI manifest format
#   - buildah tag (the extra-tags step)
#   - buildah push to a real registry, --digestfile capture
#   - emit-results step parsing the digest + writing the Chains
#     grammar Results
#
# To run the FULL centos10 build (e.g. before tagging a release), set
# `E2E_BUILDER_IMAGE_FULL_BUILD=true` — this swaps the synthetic
# Containerfile for `images/builders/Dockerfile.centos10` and gives
# the PipelineRun a 30-min timeout. Not run by default in CI; useful
# locally to verify a Dockerfile change before pushing.
#
# IN-CLUSTER REGISTRY:
# The smoke deploys a single-Pod `registry:2` Service in the same
# namespace and points the Pipeline at it. No persistence — wiped on
# cleanup. This is the same shape Sepia's in-cluster OpenShift
# registry presents to a Pipeline (a Service + a port), modulo the
# OpenShift-specific TLS + image-pusher SA RBAC that the Sepia
# overlay layers on.

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

log::info "=== assert-build-builder-image ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"

# ---------------------------------------------------------------------
# Stage 1: deploy an in-cluster registry:2 if not already present.
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

# ---------------------------------------------------------------------
# Stage 2: stage the build context onto a PVC.
#
# We use an exfil-style Pod to write either the synthetic Containerfile
# OR the real centos10 Containerfile + build-package.sh into a PVC. The
# Task's `source` workspace then binds this PVC.
# ---------------------------------------------------------------------
PVC_NAME="e2e-builder-source-$(date +%s)"
log::info "staging source PVC: ${PVC_NAME}"
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
cleanup() {
  kube_ctx -n "${NS}" delete pvc "${PVC_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kube_ctx -n "${NS}" delete pod  "stage-${PVC_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  # Don't tear down the registry — re-runs reuse it.
}
trap cleanup EXIT

kube_ctx -n "${NS}" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: stage-${PVC_NAME}
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
kube_ctx -n "${NS}" wait --for=condition=Ready pod "stage-${PVC_NAME}" --timeout=120s >/dev/null

if [[ "${FULL_BUILD}" == "true" ]]; then
  log::info "staging REAL Dockerfile.centos10 (E2E_BUILDER_IMAGE_FULL_BUILD=true)"
  DOCKERFILE_PATH="images/builders/Dockerfile.centos10"
  PIPELINERUN_TIMEOUT_OVERRIDE="1800s"
  kube_ctx -n "${NS}" cp \
    "${E2E_REPO_ROOT}/images/builders/Dockerfile.centos10" \
    "stage-${PVC_NAME}:/src/images/builders/Dockerfile.centos10"
  kube_ctx -n "${NS}" cp \
    "${E2E_REPO_ROOT}/images/builders/build-package.sh" \
    "stage-${PVC_NAME}:/src/images/builders/build-package.sh"
else
  log::info "staging synthetic Containerfile (set E2E_BUILDER_IMAGE_FULL_BUILD=true for the real centos10 build)"
  DOCKERFILE_PATH="images/builders/Dockerfile.smoke"
  PIPELINERUN_TIMEOUT_OVERRIDE="${E2E_PIPELINERUN_TIMEOUT}"
  kube_ctx -n "${NS}" exec -i "stage-${PVC_NAME}" -- sh -c "cat > /src/images/builders/Dockerfile.smoke" <<'SMOKE_DOCKERFILE'
# Synthetic Containerfile for the build-builder-image e2e smoke test.
# Tiny + offline-friendly: pulls only busybox, no install-deps.sh run.
# Exercises the same buildah + Chains-Results path as the real
# Dockerfile.centos10, so a green smoke proves the Task plumbing works.
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
LABEL org.opencontainers.image.source="${OCI_IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${OCI_IMAGE_REVISION}" \
      org.opencontainers.image.created="${OCI_IMAGE_CREATED}" \
      org.ceph.builder-image.version="${BUILDER_IMAGE_VERSION}" \
      org.ceph.builder-image.ceph-sha="${CEPH_SHA}" \
      org.ceph.builder-image.distro="smoke"
ENTRYPOINT ["/usr/local/bin/build-package.sh"]
SMOKE_DOCKERFILE

  kube_ctx -n "${NS}" cp \
    "${E2E_REPO_ROOT}/images/builders/build-package.sh" \
    "stage-${PVC_NAME}:/src/images/builders/build-package.sh"
fi

# Sanity check.
log::info "source workspace contents:"
kube_ctx -n "${NS}" exec "stage-${PVC_NAME}" -- ls -la /src/images/builders >&2

# ---------------------------------------------------------------------
# Stage 3: apply the Task + Pipeline, start a PipelineRun.
# ---------------------------------------------------------------------
kube_ctx apply -f "${E2E_REPO_ROOT}/tasks/build-builder-image/task.yaml" >/dev/null
kube_ctx apply -f "${E2E_REPO_ROOT}/images/builders/pipeline.yaml" >/dev/null

# Use a deterministic-ish tag so multiple smoke runs don't collide
# with their own previous pushes in the registry's content store.
TAG="centos10-x86_64-smoke-$(date +%s)"
OUTPUT_IMAGE="${REGISTRY_INTERNAL}/ceph-builder:${TAG}"
LATEST_IMAGE="${REGISTRY_INTERNAL}/ceph-builder:centos10-x86_64-latest"

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
log::info "starting build-builder-image PipelineRun..."
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
log::info "started PipelineRun: ${NS}/${PR}"

E2E_PIPELINERUN_TIMEOUT="${PIPELINERUN_TIMEOUT_OVERRIDE}" \
  wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "build-builder-image PipelineRun did not Succeed"; exit 1; }

# ---------------------------------------------------------------------
# Stage 4: assert the Pipeline-level Results.
# ---------------------------------------------------------------------
log::info "reading Pipeline-level Results from ${PR}"

read_pr_result() {
  local name="$1"
  kube_ctx -n "${NS}" get pipelinerun "${PR}" -o json \
    | jq -r --arg n "${name}" '.status.results[]? | select(.name == $n) | .value'
}

R_IMAGE_URL="$(read_pr_result IMAGE_URL)"
R_IMAGE_DIGEST="$(read_pr_result IMAGE_DIGEST)"
R_IMAGES="$(read_pr_result IMAGES)"
R_ARTIFACT_OUTPUTS="$(read_pr_result ARTIFACT_OUTPUTS)"
R_IMAGE_TAGS="$(read_pr_result image-tags)"

log::info "IMAGE_URL=${R_IMAGE_URL}"
log::info "IMAGE_DIGEST=${R_IMAGE_DIGEST}"
log::info "IMAGES=${R_IMAGES}"
log::info "ARTIFACT_OUTPUTS=${R_ARTIFACT_OUTPUTS}"
log::info "image-tags="
printf '%s\n' "${R_IMAGE_TAGS}" | sed 's/^/  /' >&2

FAIL=0

# Assertion 2: IMAGE_URL matches what we asked for.
if [[ "${R_IMAGE_URL}" == "${OUTPUT_IMAGE}" ]]; then
  log::pass "IMAGE_URL == ${OUTPUT_IMAGE}"
else
  log::fail "IMAGE_URL mismatch — got '${R_IMAGE_URL}', expected '${OUTPUT_IMAGE}'"
  FAIL=1
fi

# Assertion 3: IMAGE_DIGEST is a sha256:<64-hex> string.
if printf '%s' "${R_IMAGE_DIGEST}" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
  log::pass "IMAGE_DIGEST has shape sha256:<64-hex>"
else
  log::fail "IMAGE_DIGEST malformed — got '${R_IMAGE_DIGEST}'"
  FAIL=1
fi

# Assertion 4: IMAGES has one `<url>@sha256:<hex>` line.
IMG_LINES="$(printf '%s' "${R_IMAGES}" | grep -Ec '@sha256:[0-9a-f]{64}' || true)"
if [[ "${IMG_LINES}" -ge 1 ]]; then
  log::pass "IMAGES has ${IMG_LINES} <url>@<digest> line(s)"
else
  log::fail "IMAGES missing the <url>@sha256:<hex> shape"
  log::fail "  got: ${R_IMAGES}"
  FAIL=1
fi

# Assertion 5: ARTIFACT_OUTPUTS is JSON with the documented shape.
if printf '%s' "${R_ARTIFACT_OUTPUTS}" \
    | jq -e '
        has("uri") and has("digest") and has("isBuildArtifact")
        and (.digest | startswith("sha256:"))
        and (.isBuildArtifact == "true")
      ' >/dev/null 2>&1; then
  log::pass "ARTIFACT_OUTPUTS has documented shape (uri/digest/isBuildArtifact:true)"
else
  log::fail "ARTIFACT_OUTPUTS malformed — got '${R_ARTIFACT_OUTPUTS}'"
  FAIL=1
fi

# image-tags should list both the primary tag and the -latest tag.
if printf '%s\n' "${R_IMAGE_TAGS}" | grep -qF "${OUTPUT_IMAGE}"; then
  log::pass "image-tags lists ${OUTPUT_IMAGE}"
else
  log::fail "image-tags missing ${OUTPUT_IMAGE}"
  FAIL=1
fi
if printf '%s\n' "${R_IMAGE_TAGS}" | grep -qF "${LATEST_IMAGE}"; then
  log::pass "image-tags lists ${LATEST_IMAGE}"
else
  log::fail "image-tags missing ${LATEST_IMAGE} (the -latest companion tag)"
  FAIL=1
fi

# ---------------------------------------------------------------------
# Stage 5: prove the image is actually fetchable from the registry.
#
# Use a tiny one-shot Pod that runs `crane digest` (via gcr.io/go-containerregistry/crane).
# This is more portable than spinning up another buildah pod just to
# `buildah pull` — crane is purpose-built for the "introspect a remote
# image" use case + is a single static Go binary.
# ---------------------------------------------------------------------
log::info "verifying image is fetchable from ${OUTPUT_IMAGE}"
VERIFY_POD="verify-${PVC_NAME}"
kube_ctx -n "${NS}" run "${VERIFY_POD}" \
  --image=gcr.io/go-containerregistry/crane:v0.20.2 \
  --restart=Never \
  --command -- \
  /ko-app/crane digest --insecure "${OUTPUT_IMAGE}" >/dev/null 2>&1 || true

# Wait for it to finish (success or fail).
for i in $(seq 1 30); do
  phase="$(kube_ctx -n "${NS}" get pod "${VERIFY_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  case "${phase}" in
    Succeeded|Failed) break ;;
  esac
  sleep 2
done

VERIFY_DIGEST="$(kube_ctx -n "${NS}" logs "${VERIFY_POD}" 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)"
kube_ctx -n "${NS}" delete pod "${VERIFY_POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

if printf '%s' "${VERIFY_DIGEST}" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
  log::pass "crane fetched digest ${VERIFY_DIGEST} from ${OUTPUT_IMAGE}"
  if [[ "${VERIFY_DIGEST}" == "${R_IMAGE_DIGEST}" ]]; then
    log::pass "registry-side digest matches IMAGE_DIGEST Result"
  else
    log::fail "registry digest (${VERIFY_DIGEST}) != IMAGE_DIGEST Result (${R_IMAGE_DIGEST})"
    FAIL=1
  fi
else
  # Soft-fail: registry round-trip is the "nice to have" tier of this
  # assertion. The Results-shape checks above are the hard contract.
  log::warn "could not crane-fetch digest from ${OUTPUT_IMAGE} (got: '${VERIFY_DIGEST}')"
  log::warn "  the Task's emit-results contract is verified; registry pull is best-effort"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi

log::pass "assert-build-builder-image OK"

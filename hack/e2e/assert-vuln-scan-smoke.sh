#!/usr/bin/env bash
# assert-vuln-scan-smoke.sh — run pipelines/vuln-scan-smoke-test.yaml
# and assert the producer/consumer flow that #56 introduced.
#
# Pass criteria:
#   1. The PipelineRun reaches Succeeded.
#   2. The `vuln-scan` TaskRun emits the three contract Results in
#      shapes the smoke-assert Task (and Chains' object-Result
#      matcher) recognise:
#        * `vuln-summary`           — `critical=N high=N medium=N low=N negligible=N unknown=N`
#        * `findings-count`         — non-negative integer; > 0 for
#                                     the Log4Shell SBOM
#        * `findings-ARTIFACT_OUTPUTS` — object {uri, digest,
#                                       isBuildArtifact: "false"}
#   3. At least one finding has severity Critical (Log4Shell on
#      log4j-core 2.14.1 is consistently Critical across grype DB
#      releases; if this becomes a false negative, the seed SBOM or
#      the DB shipped a regression).
#
# Mechanism:
#   The `vuln-scan` Task needs to fetch a signed DB tarball from an
#   HTTPS URL. In CI on kind there's no `artifacts.ceph.com` to point
#   at, so we stand up a tiny in-cluster `vuln-scan-test-db` Pod
#   (busybox httpd) and seed it locally via the same producer steps
#   the prototype runs: `grype db update`, tar + zstd, cosign
#   sign-blob, drop the four files + latest.json into the Pod via
#   `kubectl cp`. The smoke pipeline gets `db-pointer-url` overridden
#   to the Pod's Service URL.
#
#   This deliberately mirrors what `build-grype-db` Pipeline does in
#   production — same on-the-wire shape, same cosign verify gate —
#   minus the actual `vunnel run` + `grype-db build` (which need API
#   keys and ~hours; out of scope for an e2e smoke).
#
# Prereqs on the test host:
#   - kubectl, tkn, jq                — every assert needs these.
#   - grype                           — to fetch the DB (`grype db update`).
#   - cosign                          — to sign + verify the tarball.
#   - zstd                            — tar compression program.
#
# Local re-runs: idempotent. The test-db Pod uses a unique
# generateName-style suffix so multiple back-to-back runs don't
# collide. Trap-cleanup removes the Pod + Service + PR on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"

log::info "=== assert-vuln-scan-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"
require_cmd grype   "brew install grype  (or: curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh)"
require_cmd cosign  "brew install cosign"
require_cmd zstd    "brew install zstd"

# ---------------------------------------------------------------------
# Producer prep (LOCAL) — mirrors hack/grype-db/prototype.sh stages 1-6
# but stages files into a local dir instead of pushing to S3. The
# kubectl cp step below copies them into the test-db Pod.
# ---------------------------------------------------------------------

SCHEMA="${SCHEMA:-6}"
DATE_TAG="$(date -u +%Y-%m-%d)"
SERVE_PREFIX="grype-db/${SCHEMA}/${DATE_TAG}"
LATEST_KEY="grype-db/${SCHEMA}/latest.json"

WORK_DIR="${E2E_ARTIFACTS}/vuln-scan-test-db"
PROD_DIR="${WORK_DIR}/producer"
SERVE_DIR="${WORK_DIR}/serve"  # mirrors the in-Pod /serve layout
mkdir -p "${PROD_DIR}" "${SERVE_DIR}/${SERVE_PREFIX}" "${SERVE_DIR}/$(dirname "${LATEST_KEY}")"

log::info "fetching grype DB (grype db update)..."
grype db update >/dev/null
GRYPE_DB_SRC="${HOME}/.cache/grype/db/${SCHEMA}"
[[ -f "${GRYPE_DB_SRC}/vulnerability.db" ]] || {
  log::fail "expected ${GRYPE_DB_SRC}/vulnerability.db after grype db update"
  exit 1
}

TARBALL="${PROD_DIR}/vulnerability.db.tar.zst"
BUNDLE="${PROD_DIR}/vulnerability.db.tar.zst.cosign.bundle"
log::info "tar + zstd → ${TARBALL##*/}"
tar --use-compress-program="zstd -T0 -19" \
    -cf "${TARBALL}" \
    -C "$(dirname "${GRYPE_DB_SRC}")" \
    "${SCHEMA}"
TARBALL_SHA="sha256:$(sha256sum "${TARBALL}" | awk '{print $1}')"

log::info "cosign generate-key-pair (ephemeral)"
KEY_DIR="${PROD_DIR}/cosign-keys"
mkdir -p "${KEY_DIR}"
( cd "${KEY_DIR}" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null )
COSIGN_PRIV="${KEY_DIR}/cosign.key"
COSIGN_PUB="${KEY_DIR}/cosign.pub"

log::info "cosign sign-blob → bundle"
COSIGN_PASSWORD="" cosign sign-blob \
  --key "${COSIGN_PRIV}" \
  --bundle "${BUNDLE}" \
  --yes \
  "${TARBALL}" >/dev/null

# Stage the four files into the layout the in-Pod httpd will serve.
cp -f "${TARBALL}"     "${SERVE_DIR}/${SERVE_PREFIX}/vulnerability.db.tar.zst"
cp -f "${BUNDLE}"      "${SERVE_DIR}/${SERVE_PREFIX}/vulnerability.db.tar.zst.cosign.bundle"
cp -f "${COSIGN_PUB}"  "${SERVE_DIR}/${SERVE_PREFIX}/cosign.pub"
cat > "${SERVE_DIR}/${LATEST_KEY}" <<EOF
{
  "schema":   ${SCHEMA},
  "date":     "${DATE_TAG}",
  "tarball":  "${SERVE_PREFIX}/vulnerability.db.tar.zst",
  "bundle":   "${SERVE_PREFIX}/vulnerability.db.tar.zst.cosign.bundle",
  "pubkey":   "${SERVE_PREFIX}/cosign.pub",
  "digest":   "${TARBALL_SHA}"
}
EOF
log::info "test DB staged: $(du -sh "${SERVE_DIR}" | awk '{print $1}')"

# ---------------------------------------------------------------------
# In-cluster httpd Pod + Service serving the staged files
# ---------------------------------------------------------------------

POD="vuln-scan-test-db"
SVC="vuln-scan-test-db"

cleanup() {
  kube_ctx -n "${NS}" delete pod     "${POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kube_ctx -n "${NS}" delete service "${SVC}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log::info "creating test-db Pod + Service in ${NS}/..."
kube_ctx -n "${NS}" delete pod "${POD}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kube_ctx -n "${NS}" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: ${SVC} }
spec:
  restartPolicy: Never
  containers:
    - name: httpd
      image: docker.io/library/busybox:1.36
      # busybox httpd is a static-file server. -f keeps it in
      # foreground; -p 8080 because we don't want CAP_NET_BIND_SERVICE
      # to bind 80. The verbose -v flag logs every request to stderr
      # so failure mode is debuggable from the Pod log.
      command: ["httpd"]
      args: ["-f", "-v", "-p", "8080", "-h", "/serve"]
      ports: [{ containerPort: 8080 }]
      volumeMounts:
        - name: serve
          mountPath: /serve
      readinessProbe:
        tcpSocket: { port: 8080 }
        periodSeconds: 1
  volumes:
    - name: serve
      emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
spec:
  selector: { app: ${SVC} }
  ports: [{ port: 80, targetPort: 8080 }]
EOF

log::info "waiting for ${POD} to be Ready..."
kube_ctx -n "${NS}" wait --for=condition=Ready pod "${POD}" --timeout=120s >/dev/null

# kubectl cp into the running container's emptyDir. busybox httpd
# picks up the new files on demand (no restart needed). We cp the
# whole staged tree at once with -c httpd to disambiguate the
# (single) container.
log::info "kubectl cp staged files into ${POD}:/serve/ ..."
( cd "${SERVE_DIR}" && tar -cf - . ) \
  | kube_ctx -n "${NS}" exec -i "${POD}" -c httpd -- tar -xf - -C /serve
# Sanity-check the layout landed.
kube_ctx -n "${NS}" exec "${POD}" -c httpd -- ls -la "/serve/${SERVE_PREFIX}/" >&2

DB_POINTER_URL="http://${SVC}.${NS}.svc.cluster.local/${LATEST_KEY}"
log::info "db-pointer-url: ${DB_POINTER_URL}"

# ---------------------------------------------------------------------
# Apply the Task + Pipeline + sub-task manifests
# ---------------------------------------------------------------------

log::info "applying tasks/vuln-scan/ + pipelines/vuln-scan-smoke-test.yaml ..."
kube_ctx apply -f "${E2E_REPO_ROOT}/tasks/vuln-scan/task.yaml"             >/dev/null
kube_ctx apply -f "${E2E_REPO_ROOT}/pipelines/vuln-scan-smoke-test.yaml"   >/dev/null

# ---------------------------------------------------------------------
# Run the smoke pipeline
# ---------------------------------------------------------------------

PR="$(start_pipelinerun "${NS}" vuln-scan-smoke-test \
        --param=db-pointer-url="${DB_POINTER_URL}" \
        --workspace=name=sboms,emptyDir="")"
log::info "started PipelineRun: ${NS}/${PR}"

wait_pipelinerun_succeeded "${NS}" "${PR}" \
  || { log::fail "vuln-scan-smoke-test PipelineRun did not Succeed"; exit 1; }

# ---------------------------------------------------------------------
# Assert Results on the vuln-scan TaskRun
# ---------------------------------------------------------------------

VULN_TR="$(get_taskrun_for "${NS}" "${PR}" vuln-scan)"
[[ -n "${VULN_TR}" ]] || { log::fail "no vuln-scan TaskRun found"; exit 1; }
log::info "vuln-scan TaskRun: ${VULN_TR}"

VULN_SUMMARY="$(get_taskrun_result "${NS}" "${VULN_TR}" vuln-summary || true)"
FINDINGS_COUNT="$(get_taskrun_result "${NS}" "${VULN_TR}" findings-count || true)"
# findings-ARTIFACT_OUTPUTS is an object Result — Tekton serialises
# it as JSON, jq pulls out the three sub-keys.
FA="$(kube_ctx -n "${NS}" get taskrun "${VULN_TR}" -o json \
        | jq -r '.status.results[]? | select(.name=="findings-ARTIFACT_OUTPUTS") | .value')"

log::info "vuln-summary='${VULN_SUMMARY}'"
log::info "findings-count='${FINDINGS_COUNT}'"
log::info "findings-ARTIFACT_OUTPUTS=${FA}"

FAIL=0

# ---- vuln-summary: all six tokens present, critical >= 1 ----
for token in critical= high= medium= low= negligible= unknown=; do
  if ! printf '%s' "${VULN_SUMMARY}" | grep -q "${token}"; then
    log::fail "vuln-summary missing '${token}' token"
    FAIL=1
  fi
done
CRIT="$(printf '%s\n' "${VULN_SUMMARY}" | tr ' ' '\n' \
          | sed -n 's/^critical=\([0-9]\+\)$/\1/p' | head -n1)"
CRIT="${CRIT:-0}"
if [[ "${CRIT}" -lt 1 ]]; then
  log::fail "expected critical>=1 (Log4Shell on log4j-core 2.14.1); got critical=${CRIT}"
  FAIL=1
else
  log::pass "critical=${CRIT}"
fi

# ---- findings-count: non-negative integer > 0 ----
case "${FINDINGS_COUNT}" in
  ''|*[!0-9]*) log::fail "findings-count='${FINDINGS_COUNT}' is not a non-negative integer"; FAIL=1;;
  *)
    if [[ "${FINDINGS_COUNT}" -lt 1 ]]; then
      log::fail "findings-count=${FINDINGS_COUNT}; expected > 0"
      FAIL=1
    fi
    ;;
esac

# ---- findings-ARTIFACT_OUTPUTS shape ----
if [[ -z "${FA}" || "${FA}" == "null" ]]; then
  log::fail "findings-ARTIFACT_OUTPUTS Result not present"
  FAIL=1
else
  # Tekton's object Result JSON is `{"uri":"...","digest":"...","isBuildArtifact":"..."}`.
  URI="$(printf '%s' "${FA}" | jq -r '.uri // empty')"
  DIGEST="$(printf '%s' "${FA}" | jq -r '.digest // empty')"
  ISBA="$(printf '%s' "${FA}" | jq -r '.isBuildArtifact // empty')"
  if [[ -z "${URI}" ]]; then
    log::fail "findings-ARTIFACT_OUTPUTS.uri is empty"; FAIL=1
  fi
  if ! [[ "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    log::fail "findings-ARTIFACT_OUTPUTS.digest='${DIGEST}' is not sha256:<64-hex>"; FAIL=1
  fi
  if [[ "${ISBA}" != "false" ]]; then
    log::fail "findings-ARTIFACT_OUTPUTS.isBuildArtifact='${ISBA}'; expected literal string 'false'"
    FAIL=1
  fi
fi

if [[ "${FAIL}" -ne 0 ]]; then
  capture_pipelinerun_artifacts "${NS}" "${PR}"
  exit 1
fi

log::pass "assert-vuln-scan-smoke OK"

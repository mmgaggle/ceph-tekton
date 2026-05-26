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
# Mechanism (issue #64):
#   The `vuln-scan` Task fetches a signed DB tarball from an
#   HTTP(S) URL pointing at a producer-written `latest.json`. In CI
#   on kind there's no `artifacts.ceph.com` to point at, but the
#   dev cluster ships an in-cluster S3 endpoint at
#       http://zgw-posix.zgw-posix.svc.cluster.local
#   (see kustomize/base/zgw-posix/). This script publishes the same
#   four files the production `build-grype-db` Task writes — tarball
#   + cosign bundle + pubkey + latest.json — under
#       s3://${BUCKET}/grype-db/${SCHEMA}/${DATE_TAG}/...
#       s3://${BUCKET}/grype-db/${SCHEMA}/latest.json
#   matching the exact key layout the build-grype-db Task's
#   `update-latest` step emits (see tasks/build-grype-db/task.yaml).
#   The smoke pipeline then gets `db-pointer-url` overridden to
#       http://zgw-posix.zgw-posix.svc.cluster.local/${BUCKET}/grype-db/${SCHEMA}/latest.json
#
#   The bucket is given an anonymous-read policy on the grype-db
#   prefix so the vuln-scan Task's busybox `wget` can fetch without
#   S3 creds — same posture the terraform/modules/s3-buckets
#   `*_public_read` knob produces for the production bucket.
#
#   This replaces the prior ephemeral `vuln-scan-test-db` busybox
#   httpd Pod + `kubectl cp`-of-pre-staged-files dance. The benefit:
#       - no per-run Pod/Service lifecycle in the test
#       - exercises the REAL dev S3 path that production Tekton +
#         Sepia RGW will use
#       - the `kubectl cp` step (the slowest part of the prior
#         script) is replaced by in-process `aws s3 cp` calls over
#         the port-forwarded zgw-posix endpoint
#
# Prereqs on the test host:
#   - kubectl, tkn, jq                — every assert needs these.
#   - aws                             — to talk to the in-cluster S3.
#   - grype                           — to fetch the DB (`grype db update`).
#   - cosign                          — to sign + verify the tarball.
#   - zstd                            — tar compression program.
#
# Local re-runs: idempotent. The bucket name has a per-run suffix so
# two back-to-back runs don't collide on the public-read policy. The
# trap-cleanup deletes every object under the bucket and the bucket
# itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

NS="${NS:-default}"
ZGW_NS="${ZGW_NS:-zgw-posix}"
ZGW_SVC="${ZGW_SVC:-zgw-posix}"

# Local port for the port-forward we use to PUT objects into zgw-posix.
# In-cluster the vuln-scan Task reaches the same endpoint via the
# Service DNS name; the port-forward is producer-side only.
ZGW_LOCAL_PORT="${ZGW_LOCAL_PORT:-18082}"

# zgw-posix credentials. Match kustomize/base/zgw-posix/secret.yaml's
# defaults; an overlay that rotates them would also patch this env
# (set ACCESS_KEY / SECRET_KEY in the caller's environment).
ACCESS_KEY="${ACCESS_KEY:-cephtekton}"
SECRET_KEY="${SECRET_KEY:-cephtekton}"
REGION="${REGION:-default}"

# Per-run bucket. We intentionally pick a unique bucket per run
# (rather than reusing a static `ceph-grype-db`) so two CI runs
# against the same cluster don't see each other's pointer churn,
# and so the public-read policy's blast radius is bounded to this
# run's lifetime.
BUCKET="${BUCKET:-ceph-grype-db-smoke-$(date -u +%s)}"

SCHEMA="${SCHEMA:-6}"
DATE_TAG="$(date -u +%Y-%m-%d)"
S3_PREFIX="grype-db/${SCHEMA}/${DATE_TAG}"
LATEST_KEY="grype-db/${SCHEMA}/latest.json"

log::info "=== assert-vuln-scan-smoke ==="

require_cmd kubectl "brew install kubectl"
require_cmd tkn     "brew install tektoncd-cli"
require_cmd jq      "brew install jq"
require_cmd aws     "brew install awscli"
require_cmd grype   "brew install grype  (or: curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh)"
require_cmd cosign  "brew install cosign"
require_cmd zstd    "brew install zstd"

# ---------------------------------------------------------------------
# Producer prep (LOCAL) — mirrors hack/grype-db/prototype.sh stages 1-6
# AND tasks/build-grype-db/task.yaml's package + sign + publish +
# update-latest steps. Files are staged locally, then uploaded with
# `aws s3 cp` to the port-forwarded zgw-posix endpoint.
# ---------------------------------------------------------------------

WORK_DIR="${E2E_ARTIFACTS}/vuln-scan-test-db"
PROD_DIR="${WORK_DIR}/producer"
mkdir -p "${PROD_DIR}"

log::info "fetching grype DB (grype db update)..."
grype db update >/dev/null
GRYPE_DB_SRC="${HOME}/.cache/grype/db/${SCHEMA}"
[[ -f "${GRYPE_DB_SRC}/vulnerability.db" ]] || {
  log::fail "expected ${GRYPE_DB_SRC}/vulnerability.db after grype db update"
  exit 1
}

TARBALL="${PROD_DIR}/vulnerability.db.tar.zst"
BUNDLE="${PROD_DIR}/vulnerability.db.tar.zst.cosign.bundle"
PUBKEY="${PROD_DIR}/cosign.pub"
LATEST="${PROD_DIR}/latest.json"

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
COSIGN_PUB_SRC="${KEY_DIR}/cosign.pub"

log::info "cosign sign-blob → bundle"
COSIGN_PASSWORD="" cosign sign-blob \
  --key "${COSIGN_PRIV}" \
  --bundle "${BUNDLE}" \
  --yes \
  "${TARBALL}" >/dev/null

cp -f "${COSIGN_PUB_SRC}" "${PUBKEY}"

# Same JSON shape as tasks/build-grype-db/task.yaml's update-latest
# step writes — keep them in lockstep so the consumer parser (busybox
# sed in tasks/vuln-scan/task.yaml's fetch-db step) reads either
# producer's output unchanged.
cat > "${LATEST}" <<EOF
{
  "schema":   ${SCHEMA},
  "date":     "${DATE_TAG}",
  "tarball":  "${S3_PREFIX}/vulnerability.db.tar.zst",
  "bundle":   "${S3_PREFIX}/vulnerability.db.tar.zst.cosign.bundle",
  "pubkey":   "${S3_PREFIX}/cosign.pub",
  "digest":   "${TARBALL_SHA}"
}
EOF

log::info "producer staged: $(du -sh "${PROD_DIR}" | awk '{print $1}')"

# ---------------------------------------------------------------------
# Publish to zgw-posix via a port-forwarded `aws s3 cp`. The
# vuln-scan Task itself reaches zgw-posix via the in-cluster Service
# FQDN; the port-forward is producer-side ONLY (writes from this
# host into the in-cluster bucket).
# ---------------------------------------------------------------------

log::info "checking ${ZGW_NS}/${ZGW_SVC} Service is reachable"
if ! kube_ctx -n "${ZGW_NS}" get svc "${ZGW_SVC}" >/dev/null 2>&1; then
  log::fail "Service ${ZGW_NS}/${ZGW_SVC} not found — assert-zgw-posix-up should have run first"
  log::fail "  try: kubectl apply -k kustomize/base/zgw-posix/"
  exit 1
fi

PF_LOG="$(mktemp)"
PF_PID=""

cleanup() {
  # Best-effort: tear down the bucket so re-runs don't accumulate.
  # Object-deletion before bucket-deletion is required on zgw-posix
  # (no force-delete-with-contents) — `s3 rb --force` does both.
  if [[ -n "${ENDPOINT:-}" ]]; then
    AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
    AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
      aws --endpoint-url "${ENDPOINT}" --region "${REGION}" \
        s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
  fi
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
  rm -f "${PF_LOG}"
}
trap cleanup EXIT

log::info "port-forwarding svc/${ZGW_SVC} → localhost:${ZGW_LOCAL_PORT}"
kube_ctx -n "${ZGW_NS}" port-forward svc/"${ZGW_SVC}" "${ZGW_LOCAL_PORT}:80" \
  >"${PF_LOG}" 2>&1 &
PF_PID=$!

# Wait for the port-forward to bind. Same pattern as
# assert-zgw-posix-up.sh.
for i in $(seq 1 20); do
  if grep -q "Forwarding from" "${PF_LOG}"; then break; fi
  if ! kill -0 "${PF_PID}" 2>/dev/null; then
    log::fail "kubectl port-forward died before binding"
    cat "${PF_LOG}" >&2
    exit 1
  fi
  sleep 0.5
  if (( i == 20 )); then
    log::fail "port-forward did not bind within ~10s"
    cat "${PF_LOG}" >&2
    exit 1
  fi
done

ENDPOINT="http://127.0.0.1:${ZGW_LOCAL_PORT}"
export AWS_ACCESS_KEY_ID="${ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${SECRET_KEY}"
AWS_ARGS=(--endpoint-url "${ENDPOINT}" --region "${REGION}")

log::info "creating bucket s3://${BUCKET}/"
aws "${AWS_ARGS[@]}" s3api create-bucket --bucket "${BUCKET}" >/dev/null

# Anonymous-read policy on the grype-db/ prefix. Same shape the
# terraform `aws_iam_policy_document.public_read` produces for the
# production bucket (`s3:GetObject` to `Principal: *` on the prefix).
# The vuln-scan Task's busybox `wget` is anonymous, so without this
# the in-cluster GET would 403.
log::info "applying anonymous-read policy to s3://${BUCKET}/grype-db/*"
POLICY_FILE="$(mktemp)"
cat >"${POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAnonymousReadOnPrefixes",
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::${BUCKET}/grype-db/*"]
    }
  ]
}
EOF
aws "${AWS_ARGS[@]}" s3api put-bucket-policy \
  --bucket "${BUCKET}" --policy "file://${POLICY_FILE}" >/dev/null
rm -f "${POLICY_FILE}"

log::info "uploading producer artefacts to s3://${BUCKET}/${S3_PREFIX}/"
aws "${AWS_ARGS[@]}" s3 cp "${TARBALL}" \
  "s3://${BUCKET}/${S3_PREFIX}/vulnerability.db.tar.zst"             >/dev/null
aws "${AWS_ARGS[@]}" s3 cp "${BUNDLE}"  \
  "s3://${BUCKET}/${S3_PREFIX}/vulnerability.db.tar.zst.cosign.bundle" >/dev/null
aws "${AWS_ARGS[@]}" s3 cp "${PUBKEY}"  \
  "s3://${BUCKET}/${S3_PREFIX}/cosign.pub"                            >/dev/null
aws "${AWS_ARGS[@]}" s3 cp "${LATEST}"  \
  "s3://${BUCKET}/${LATEST_KEY}" \
  --content-type application/json                                    >/dev/null
log::info "published 4 objects (3 under ${S3_PREFIX}/, 1 latest.json pointer)"

# The URL the IN-CLUSTER vuln-scan Task hits. Path-style S3 URL
# (host/bucket/key) — works on zgw-posix and RGW alike.
DB_POINTER_URL="http://${ZGW_SVC}.${ZGW_NS}.svc.cluster.local/${BUCKET}/${LATEST_KEY}"
log::info "db-pointer-url: ${DB_POINTER_URL}"

# ---------------------------------------------------------------------
# Apply the Task + Pipeline manifests
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

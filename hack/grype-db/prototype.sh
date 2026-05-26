#!/usr/bin/env bash
# Prototype: producer/consumer split for the Grype vulnerability DB.
#
# Goal of this script: validate the SHAPE of the producer/consumer
# pipeline (#56) end-to-end against a real RGW + a real grype binary —
# before any of it gets wired into Tekton.
#
# What's exercised:
#   - tar + zstd of a grype-format SQLite DB
#   - cosign sign-blob (x509 key) of the tarball
#   - aws s3 cp publish to RGW under the documented path layout
#   - `latest.json` pointer atomic update (S3 single PUT)
#   - aws s3 cp fetch from RGW into a clean workspace
#   - cosign verify-blob against the published signature
#   - tar -xf / zstd -d unpack into the workspace
#   - grype --db-path scan of a synthetic Log4Shell SBOM
#   - assertion: Critical finding present
#
# What's INTENTIONALLY deferred to the Tekton Pipeline (#56 step 5,
# tracked as issue #56's `pipelines/build-grype-db.yaml` + Task):
#   - actual vunnel + grype-db build of the SQLite DB from upstream
#     CVE sources. This script uses anchore's pre-built DB (fetched
#     by `grype db update`) as the artifact, because the value of
#     THIS prototype is the publish + sign + consume flow, not
#     re-implementing anchore's data-pull tooling.
#   - keyless (Fulcio + Rekor) signing. The prototype uses an x509
#     keypair generated per-run; the production Tekton Pipeline on
#     Sepia signs keyless against the OpenShift OIDC issuer (same
#     pattern as the chains-smoke-test signing path).
#   - cron triggering and bucket-side lifecycle expiry of old DB
#     snapshots. Bucket lifecycle lives in `terraform/modules/s3-buckets`
#     (see `enable_lifecycle` and ceph-tekton issue #57).
#
# How to run:
#   Set the S3 endpoint + bucket + creds in the environment, then:
#     ./hack/grype-db/prototype.sh
#
#   Required env vars:
#     RGW_ENDPOINT       e.g. http://localhost:18000 (tunnel to vstart)
#     RGW_BUCKET         e.g. vstart-ceph-grype-db
#     AWS_ACCESS_KEY_ID
#     AWS_SECRET_ACCESS_KEY
#
#   Optional:
#     SCHEMA_VERSION     default 6 (current grype DB schema)
#     WORK_DIR           default $(mktemp -d) — produced + consumed artefacts land here
#     LOG4J_SBOM         path to a CycloneDX SBOM with a vulnerable
#                        log4j-core component; default: written inline
#
# Exit codes:
#   0   producer + consumer flow succeeded; Critical finding observed
#   non-zero  one of: missing prereq, S3 round-trip failure, signature
#             verification failure, grype scan didn't find Log4Shell
#
# This script is run-the-shape: each stage prints a banner so a
# failed run tells you which stage broke. The output is intentionally
# verbose so the eventual Tekton step authors can copy/paste the
# CLI invocations into Task `args:`.

set -euo pipefail

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
: "${RGW_ENDPOINT:?set RGW_ENDPOINT (e.g. http://localhost:18000)}"
: "${RGW_BUCKET:?set RGW_BUCKET (e.g. vstart-ceph-grype-db)}"
: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID for the RGW test user}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY for the RGW test user}"

SCHEMA_VERSION="${SCHEMA_VERSION:-6}"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t grype-db-proto-XXXX)}"
PROD_DIR="${WORK_DIR}/producer"
CONS_DIR="${WORK_DIR}/consumer"
mkdir -p "${PROD_DIR}" "${CONS_DIR}"

DATE_TAG="$(date -u +%Y-%m-%d)"
TARBALL_NAME="vulnerability.db.tar.zst"
BUNDLE_NAME="${TARBALL_NAME}.cosign.bundle"
PUB_NAME="cosign.pub"
LATEST_NAME="latest.json"
S3_PREFIX="grype-db/${SCHEMA_VERSION}/${DATE_TAG}"
S3_LATEST_KEY="grype-db/${SCHEMA_VERSION}/${LATEST_NAME}"

# Bundle every aws CLI invocation with the same endpoint flag.
S3() { aws --endpoint-url "${RGW_ENDPOINT}" "$@"; }

banner() { printf '\n=== %s ===\n' "$*"; }

# -----------------------------------------------------------------
# Prereq check
# -----------------------------------------------------------------
banner "0. prereq check"
for bin in grype cosign aws zstd tar sha256sum; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    # `grype` and `cosign` may live next to this script under bin/
    if [ -x "${PROTO_BIN:-./bin}/${bin}" ]; then continue; fi
    echo "FATAL: ${bin} not in PATH" >&2
    exit 2
  fi
done
grype --version
cosign version --json 2>/dev/null | head -1 || cosign version 2>&1 | head -3

# -----------------------------------------------------------------
# 1. Fetch the source DB (deferred-build path — see file header)
# -----------------------------------------------------------------
banner "1. fetch source DB via grype db update"
grype db update
# The DB lands at $HOME/.cache/grype/db/${SCHEMA_VERSION}/.
GRYPE_DB_SRC="${HOME}/.cache/grype/db/${SCHEMA_VERSION}"
if [ ! -f "${GRYPE_DB_SRC}/vulnerability.db" ]; then
  echo "FATAL: expected ${GRYPE_DB_SRC}/vulnerability.db" >&2
  exit 3
fi
echo "source DB: $(du -sh "${GRYPE_DB_SRC}" | awk '{print $1}') at ${GRYPE_DB_SRC}"

# -----------------------------------------------------------------
# 2. Tar + zstd
# -----------------------------------------------------------------
banner "2. tar + zstd → ${TARBALL_NAME}"
TARBALL="${PROD_DIR}/${TARBALL_NAME}"
# tar from the parent so the archive's top-level is `${SCHEMA_VERSION}/`
# (mirrors the on-disk grype cache layout the consumer recreates).
tar --use-compress-program="zstd -T0 -19" \
    -cf "${TARBALL}" \
    -C "$(dirname "${GRYPE_DB_SRC}")" \
    "${SCHEMA_VERSION}"
TARBALL_SHA="sha256:$(sha256sum "${TARBALL}" | awk '{print $1}')"
echo "tarball: ${TARBALL} ($(du -sh "${TARBALL}" | awk '{print $1}'), ${TARBALL_SHA})"

# -----------------------------------------------------------------
# 3. cosign keypair (per-run, ephemeral)
# -----------------------------------------------------------------
banner "3. cosign generate-key-pair (ephemeral)"
KEY_DIR="${PROD_DIR}/cosign-keys"
mkdir -p "${KEY_DIR}"
( cd "${KEY_DIR}" && COSIGN_PASSWORD="" cosign generate-key-pair >/dev/null )
COSIGN_PRIV="${KEY_DIR}/cosign.key"
COSIGN_PUB="${KEY_DIR}/cosign.pub"
test -f "${COSIGN_PRIV}" -a -f "${COSIGN_PUB}"
echo "keys: priv=${COSIGN_PRIV} pub=${COSIGN_PUB}"

# -----------------------------------------------------------------
# 4. cosign sign-blob  (sigstore bundle format)
# -----------------------------------------------------------------
banner "4. cosign sign-blob → ${BUNDLE_NAME}"
BUNDLE="${PROD_DIR}/${BUNDLE_NAME}"
# cosign 2.x deprecates --output-signature; the sigstore bundle wraps
# the signature (and, in keyless mode, the Fulcio cert + Rekor entry)
# into a single artefact the consumer verifies with --bundle.
COSIGN_PASSWORD="" cosign sign-blob \
  --key "${COSIGN_PRIV}" \
  --bundle "${BUNDLE}" \
  --yes \
  "${TARBALL}"
echo "bundle: ${BUNDLE} ($(wc -c < "${BUNDLE}") bytes)"

# -----------------------------------------------------------------
# 5. Push tarball + bundle + public key to RGW
# -----------------------------------------------------------------
banner "5. publish to s3://${RGW_BUCKET}/${S3_PREFIX}/"
S3 s3 cp "${TARBALL}"     "s3://${RGW_BUCKET}/${S3_PREFIX}/${TARBALL_NAME}"
S3 s3 cp "${BUNDLE}"      "s3://${RGW_BUCKET}/${S3_PREFIX}/${BUNDLE_NAME}"
S3 s3 cp "${COSIGN_PUB}"  "s3://${RGW_BUCKET}/${S3_PREFIX}/${PUB_NAME}"

# -----------------------------------------------------------------
# 6. Atomic latest.json pointer
# -----------------------------------------------------------------
banner "6. update latest.json pointer"
LATEST_LOCAL="${PROD_DIR}/${LATEST_NAME}"
cat > "${LATEST_LOCAL}" <<EOF
{
  "schema":   ${SCHEMA_VERSION},
  "date":     "${DATE_TAG}",
  "tarball":  "${S3_PREFIX}/${TARBALL_NAME}",
  "bundle":   "${S3_PREFIX}/${BUNDLE_NAME}",
  "pubkey":   "${S3_PREFIX}/${PUB_NAME}",
  "digest":   "${TARBALL_SHA}"
}
EOF
S3 s3 cp "${LATEST_LOCAL}" "s3://${RGW_BUCKET}/${S3_LATEST_KEY}"
echo "latest.json:"
cat "${LATEST_LOCAL}"

# -----------------------------------------------------------------
# 7. Consumer fetch (clean workspace, no shared state)
# -----------------------------------------------------------------
banner "7. consumer: fetch latest.json + tarball + signature + pubkey"
CONS_LATEST="${CONS_DIR}/${LATEST_NAME}"
S3 s3 cp "s3://${RGW_BUCKET}/${S3_LATEST_KEY}" "${CONS_LATEST}"
# parse without jq (busybox-friendly — same constraint Tekton steps will face)
CONS_TARBALL_KEY=$(sed -n 's/.*"tarball":[[:space:]]*"\([^"]*\)".*/\1/p' "${CONS_LATEST}")
CONS_BUNDLE_KEY=$(sed -n  's/.*"bundle":[[:space:]]*"\([^"]*\)".*/\1/p'  "${CONS_LATEST}")
CONS_PUB_KEY=$(sed -n     's/.*"pubkey":[[:space:]]*"\([^"]*\)".*/\1/p'  "${CONS_LATEST}")
echo "pointer parsed: tarball=${CONS_TARBALL_KEY} bundle=${CONS_BUNDLE_KEY} pub=${CONS_PUB_KEY}"

S3 s3 cp "s3://${RGW_BUCKET}/${CONS_TARBALL_KEY}" "${CONS_DIR}/${TARBALL_NAME}"
S3 s3 cp "s3://${RGW_BUCKET}/${CONS_BUNDLE_KEY}"  "${CONS_DIR}/${BUNDLE_NAME}"
S3 s3 cp "s3://${RGW_BUCKET}/${CONS_PUB_KEY}"     "${CONS_DIR}/${PUB_NAME}"

# -----------------------------------------------------------------
# 8. cosign verify-blob
# -----------------------------------------------------------------
banner "8. cosign verify-blob (sigstore bundle)"
cosign verify-blob \
  --key "${CONS_DIR}/${PUB_NAME}" \
  --bundle "${CONS_DIR}/${BUNDLE_NAME}" \
  "${CONS_DIR}/${TARBALL_NAME}"

# Belt-and-braces: independently verify content digest matches pointer.
CONS_DIGEST="sha256:$(sha256sum "${CONS_DIR}/${TARBALL_NAME}" | awk '{print $1}')"
POINTER_DIGEST=$(sed -n 's/.*"digest":[[:space:]]*"\([^"]*\)".*/\1/p' "${CONS_LATEST}")
if [ "${CONS_DIGEST}" != "${POINTER_DIGEST}" ]; then
  echo "FATAL: on-disk digest ${CONS_DIGEST} != latest.json digest ${POINTER_DIGEST}" >&2
  exit 4
fi
echo "digest match: ${CONS_DIGEST}"

# -----------------------------------------------------------------
# 9. Unpack + grype scan with --db-path
# -----------------------------------------------------------------
banner "9. unpack + grype scan"
DB_UNPACK_DIR="${CONS_DIR}/db"
mkdir -p "${DB_UNPACK_DIR}"
tar --use-compress-program="zstd -d" \
    -xf "${CONS_DIR}/${TARBALL_NAME}" \
    -C "${DB_UNPACK_DIR}"
test -f "${DB_UNPACK_DIR}/${SCHEMA_VERSION}/vulnerability.db"
echo "unpacked DB: $(du -sh "${DB_UNPACK_DIR}/${SCHEMA_VERSION}" | awk '{print $1}')"

# Synthesise the Log4Shell SBOM if the caller didn't override.
LOG4J_SBOM="${LOG4J_SBOM:-${CONS_DIR}/log4j-shell.cdx.json}"
if [ ! -f "${LOG4J_SBOM}" ]; then
  cat > "${LOG4J_SBOM}" <<'EOF'
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:00000000-0000-4000-8000-000000000001",
  "version": 1,
  "metadata": {
    "timestamp": "2023-11-14T22:13:20Z",
    "component": {"type": "application", "name": "vuln-scan-smoke", "version": "1.0.0"}
  },
  "components": [
    {
      "bom-ref": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1",
      "type": "library",
      "group": "org.apache.logging.log4j",
      "name": "log4j-core",
      "version": "2.14.1",
      "purl": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1"
    }
  ]
}
EOF
fi

# grype 0.112 took `--db-path` out; the path is now driven by
# GRYPE_DB_CACHE_DIR. Grype expects the cache dir to contain
# `<schema>/vulnerability.db` — exactly the layout our tarball unpacks
# into.
SCAN_JSON="${CONS_DIR}/findings.grype.json"
GRYPE_DB_AUTO_UPDATE=false \
GRYPE_DB_CACHE_DIR="${DB_UNPACK_DIR}" \
  grype \
    -o json \
    --file "${SCAN_JSON}" \
    "sbom:${LOG4J_SBOM}" >/dev/null
echo "scan JSON: ${SCAN_JSON} ($(wc -c < "${SCAN_JSON}") bytes)"

# -----------------------------------------------------------------
# 10. Assert Log4Shell Critical finding present
# -----------------------------------------------------------------
banner "10. assert Critical Log4Shell finding"
if ! grep -q '"id":"GHSA-jfh8-c2jp-5v3q"' "${SCAN_JSON}" \
  && ! grep -q '"id":"CVE-2021-44228"' "${SCAN_JSON}"; then
  echo "FATAL: scan JSON missing the Log4Shell advisory id" >&2
  exit 5
fi
# The Log4Shell GHSA's severity field MUST be Critical.
if ! grep -E '"severity":"Critical".*log4j-core' "${SCAN_JSON}" >/dev/null \
  && ! grep -E 'log4j-core.*"severity":"Critical"' "${SCAN_JSON}" >/dev/null; then
  # Fall back to a coarser check — sometimes grype's JSON shape
  # interleaves severity above the matched purl.
  if ! grep -q '"severity":"Critical"' "${SCAN_JSON}"; then
    echo "FATAL: no Critical severity in scan JSON" >&2
    exit 5
  fi
fi

CRIT_COUNT=$(grep -oE '"severity":"Critical"' "${SCAN_JSON}" | wc -l | tr -d ' ')
echo "Critical findings in scan: ${CRIT_COUNT}"

banner "PROTOTYPE OK — producer + consumer round-trip verified"
echo "S3 path published:   s3://${RGW_BUCKET}/${S3_PREFIX}/"
echo "Pointer key:         s3://${RGW_BUCKET}/${S3_LATEST_KEY}"
echo "Workspace retained:  ${WORK_DIR}"

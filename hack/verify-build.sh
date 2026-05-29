#!/usr/bin/env bash
# hack/verify-build.sh — end-to-end SLSA-attestation verifier for any
# ceph-tekton-published artifact (container image OR .deb / .rpm
# package), using only public-good Sigstore infrastructure (Fulcio
# root + Rekor transparency log) and `cosign` + `rekor-cli` + `curl`.
#
# Closes mmgaggle/ceph-tekton#28 (W8, phase 1).
#
# ============================================================
# What this script proves
# ============================================================
#
# Given a single artifact URL, this script asserts:
#
#   1. The artifact carries a Sigstore signature whose Fulcio cert
#      chains back to the public-good Sigstore root.
#   2. The certificate identity matches the expected signer (a Sepia
#      ServiceAccount for production builds, or a parameterised
#      identity for dev / test builds — see --certificate-identity
#      below).
#   3. The artifact carries a SLSA Provenance v1.0 in-toto attestation
#      (`predicateType: https://slsa.dev/provenance/v1`) signed by the
#      SAME Fulcio cert.
#   4. The signature is recorded in the public Sigstore Rekor
#      transparency log — the verifier proves the entry by inclusion
#      via `cosign verify --rekor-url ...` (cosign's verify path
#      performs the Rekor lookup + inclusion proof internally) and
#      additionally surfaces a `rekor-cli search` hit so the
#      operator's "I can find this in Rekor" experience matches the
#      AC bullet in #28.
#
# All of the above run with no Sepia cluster access, no Sepia AWS
# creds, and no project-side dependencies — exactly the external-
# consumer posture the W8 milestone targets.
#
# ============================================================
# Why one script with two modes (image + package)
# ============================================================
#
# The Sepia signing chain wired by #113 is single-shape: every
# PipelineRun (container build OR package build) emits the SAME
# slsa/v2alpha4 / SLSA Provenance v1.0 attestation, keyless-signed
# by Fulcio via the cluster SA-token OIDC path, logged to public
# Rekor. The only externally visible difference is WHERE the
# attestation lives:
#
#   * Container image — the attestation is attached to the image as
#     a cosign referrer in the OCI registry (the image-build pipeline
#     issue #26 enables `artifacts.oci.storage=oci`; today's Sepia
#     build pipeline lands packages, so this branch is the path
#     for #26-and-later image-publish work). cosign discovers the
#     referrer by digest; `cosign verify` + `cosign verify-attestation`
#     are the standard one-liners.
#
#   * `.deb` / `.rpm` package — packages don't live in an OCI
#     registry. docs/provenance.md §"Per-package SLSA attestations
#     as S3 siblings (#27)" specifies the publish-repo Task (#19 /
#     #20) writes the per-package in-toto Statement as
#     `<artifact-prefix>/attestations/<pkg>.intoto.jsonl` next to
#     the `.deb` / `.rpm`. This branch fetches both files and runs
#     `cosign verify-blob-attestation` against the pair.
#
# Detection logic is intentionally simple (URL suffix), with an
# escape hatch (--type) for ambiguous inputs (e.g. an HTTPS URL
# that serves an OCI manifest).
#
# ============================================================
# What this script INTENTIONALLY does not do
# ============================================================
#
# * Doesn't touch kubectl. Pure external verification.
# * Doesn't shell out to `aws s3 cp`. Public artifacts must be
#   reachable over HTTPS (the publish-repo Task uploads them to a
#   bucket exposed via the artifacts.ceph.com CDN domain documented
#   in PLAN.md §"Artifact storage"). If a user has an `s3://` URI,
#   they need to convert it to its HTTPS equivalent — the helpful-
#   error path below explains how.
# * Doesn't install cosign / rekor-cli / curl. Missing-tool errors
#   carry an install hint; we don't auto-install third-party tooling.
# * Doesn't try to verify the running cluster's signing identity by
#   reading kube-apiserver discovery. The expected identity is a
#   CLI parameter (or env var); the user supplies it from whatever
#   trust source they consider authoritative (docs/provenance.md,
#   org runbook, etc.). That keeps the script honest: "the verifier
#   trusts what the operator told it to trust", not "the verifier
#   trusts whatever the cluster says about itself".
#
# ============================================================
# Usage
# ============================================================
#
#   hack/verify-build.sh [flags] <artifact-url>
#
# Where <artifact-url> is one of:
#
#   * An OCI reference, BY DIGEST:
#       quay.io/ceph/ceph@sha256:abcd...
#       quay.io/ceph/ceph:v19.2.0@sha256:abcd...   (tag+digest form)
#
#   * An HTTPS URL to a .deb or .rpm package:
#       https://artifacts.ceph.com/main/<sha>/centos10/x86_64/ceph-mds_19.2.0_arm64.deb
#       https://artifacts.ceph.com/main/<sha>/centos10/x86_64/ceph-19.2.0-1.el9.x86_64.rpm
#
# Flags:
#
#   --type IMAGE|PACKAGE
#       Force the verification path. Default: auto-detected from the
#       URL suffix.
#
#   --certificate-identity URI
#       Expected Fulcio certificate identity URI. Required for
#       keyless verification; no built-in default because the value
#       depends on which cluster produced the artifact (and we
#       refuse to silently trust an "any identity" path).
#       For Sepia builds the expected shape is:
#         https://kubernetes.default.svc.cluster.local/namespaces/sepia-pipelines/serviceaccounts/ceph-pipeline-sa
#       which is what Chains' Kubernetes-provider Fulcio path emits
#       per the Sepia TektonConfig.spec.chain block.
#       Env: CEPH_VERIFY_BUILD_CERT_IDENTITY.
#
#   --certificate-identity-regexp REGEX
#       Use a regexp instead of an exact match. Useful when the
#       expected identity URI contains the cluster's kube-apiserver
#       hostname which isn't stable across rebuilds.
#       Env: CEPH_VERIFY_BUILD_CERT_IDENTITY_REGEXP.
#
#   --certificate-oidc-issuer URL
#       Expected OIDC issuer URL on the Fulcio cert. For Sepia builds
#       this is the OpenShift cluster's SA-token issuer URL — the
#       value of the kube-apiserver `--service-account-issuer` flag.
#       Required for keyless verification.
#       Env: CEPH_VERIFY_BUILD_CERT_OIDC_ISSUER.
#
#   --rekor-url URL
#       Rekor transparency log instance. Default: the public-good
#       Sigstore Rekor (https://rekor.sigstore.dev) — same default as
#       the in-cluster verify-image-signature Task.
#       Env: CEPH_VERIFY_BUILD_REKOR_URL.
#
#   --workdir DIR
#       Where to drop downloaded files + cosign output. Default: a
#       fresh per-run mktemp directory, cleaned up on exit (unless
#       --keep-workdir is passed for forensics).
#       Env: CEPH_VERIFY_BUILD_WORKDIR.
#
#   --keep-workdir
#       Don't delete the workdir on exit.
#
#   -h, --help
#       Print this header and exit 0.
#
# Exit codes:
#
#   0   all verifications passed
#   1   verification failed (any of: cosign error, identity mismatch,
#       Rekor lookup empty)
#   2   bad usage (missing required flag, malformed URL, missing
#       prereq tool)
#
# ============================================================
# Examples
# ============================================================
#
#   # Verify a Sepia-published container image:
#   hack/verify-build.sh \
#     --certificate-identity \
#       'https://kubernetes.default.svc.cluster.local/namespaces/sepia-pipelines/serviceaccounts/ceph-pipeline-sa' \
#     --certificate-oidc-issuer \
#       'https://kubernetes.default.svc' \
#     quay.io/ceph/ceph@sha256:abcdef0123456789...
#
#   # Verify a Sepia-published .deb (the .intoto.jsonl sibling is
#   # discovered under <prefix>/attestations/<pkg>.intoto.jsonl):
#   hack/verify-build.sh \
#     --certificate-identity \
#       'https://kubernetes.default.svc.cluster.local/namespaces/sepia-pipelines/serviceaccounts/ceph-pipeline-sa' \
#     --certificate-oidc-issuer \
#       'https://kubernetes.default.svc' \
#     https://artifacts.ceph.com/main/abc123/centos10/x86_64/ceph-mds_19.2.0_arm64.deb
#
# ============================================================
# Implementation
# ============================================================

set -euo pipefail

# ---------------------------------------------------------------------
# pretty-printers — single-file equivalent of hack/e2e/lib.sh's log::*.
# All output goes to stderr so the script's stdout stays parseable for
# any future consumer that wants to chain it.
# ---------------------------------------------------------------------
log::info() { printf '\033[1;34m[verify-build] %s\033[0m\n' "$*" >&2; }
log::pass() { printf '\033[1;32m[PASS] %s\033[0m\n' "$*" >&2; }
log::fail() { printf '\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; }
log::warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }

require_cmd() {
  local cmd="$1" hint="$2"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log::fail "required tool '${cmd}' not found on PATH"
    log::fail "  install: ${hint}"
    exit 2
  fi
}

usage() {
  # Print every top-of-file comment line up to the first non-comment
  # line so `hack/verify-build.sh --help` is the man page. Header is
  # already structured as the docs; no point duplicating it inline.
  awk '
    NR == 1 { next }                 # skip shebang
    /^#!/   { next }                 # skip any later shebang lines (none today)
    /^[[:space:]]*$/ && !in_body { exit }   # blank before code = end of header
    /^#/ { sub(/^# ?/, ""); print; in_body = 1; next }
    { exit }                         # first non-comment line = end of header
  ' "$0" >&2
}

# ---------------------------------------------------------------------
# flag parsing
# ---------------------------------------------------------------------
TYPE_OVERRIDE=""
CERT_IDENTITY="${CEPH_VERIFY_BUILD_CERT_IDENTITY:-}"
CERT_IDENTITY_REGEXP="${CEPH_VERIFY_BUILD_CERT_IDENTITY_REGEXP:-}"
CERT_OIDC_ISSUER="${CEPH_VERIFY_BUILD_CERT_OIDC_ISSUER:-}"
REKOR_URL="${CEPH_VERIFY_BUILD_REKOR_URL:-https://rekor.sigstore.dev}"
WORKDIR_OVERRIDE="${CEPH_VERIFY_BUILD_WORKDIR:-}"
KEEP_WORKDIR=0
ARTIFACT_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      TYPE_OVERRIDE="${2:-}"; shift 2
      ;;
    --certificate-identity)
      CERT_IDENTITY="${2:-}"; shift 2
      ;;
    --certificate-identity-regexp)
      CERT_IDENTITY_REGEXP="${2:-}"; shift 2
      ;;
    --certificate-oidc-issuer)
      CERT_OIDC_ISSUER="${2:-}"; shift 2
      ;;
    --rekor-url)
      REKOR_URL="${2:-}"; shift 2
      ;;
    --workdir)
      WORKDIR_OVERRIDE="${2:-}"; shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; ARTIFACT_URL="${1:-}"; shift; break
      ;;
    -*)
      log::fail "unknown flag: $1"
      usage
      exit 2
      ;;
    *)
      if [[ -n "${ARTIFACT_URL}" ]]; then
        log::fail "more than one artifact-url given: '${ARTIFACT_URL}' and '$1'"
        exit 2
      fi
      ARTIFACT_URL="$1"; shift
      ;;
  esac
done

if [[ -z "${ARTIFACT_URL}" ]]; then
  log::fail "missing required positional argument: <artifact-url>"
  usage
  exit 2
fi

# ---------------------------------------------------------------------
# Resolve required identity. We refuse to verify against an "any
# identity" policy because that would silently accept ANY Fulcio-issued
# cert (including one for an attacker's GitHub Action), defeating the
# point of keyless. The user must tell us which identity to trust.
# ---------------------------------------------------------------------
if [[ -z "${CERT_IDENTITY}" && -z "${CERT_IDENTITY_REGEXP}" ]]; then
  log::fail "neither --certificate-identity nor --certificate-identity-regexp is set"
  log::fail "  Keyless verification REQUIRES a pinned signer identity. Without one,"
  log::fail "  cosign would accept any Fulcio-issued cert, defeating the purpose."
  log::fail "  See docs/provenance.md for the expected Sepia identity URI."
  exit 2
fi
if [[ -z "${CERT_OIDC_ISSUER}" ]]; then
  log::fail "--certificate-oidc-issuer is required for keyless verification"
  log::fail "  For Sepia builds this is the OpenShift cluster's SA-token issuer URL."
  log::fail "  See docs/provenance.md §'Promoting to Fulcio keyless (Sepia)'."
  exit 2
fi

# ---------------------------------------------------------------------
# Prereqs.
# rekor-cli is required even though cosign verify already does Rekor
# inclusion: AC #28 asks for `rekor-cli search` to demonstrate the
# transparency-log path explicitly, not just implicitly via cosign.
# ---------------------------------------------------------------------
require_cmd cosign    "brew install cosign  (or https://docs.sigstore.dev/cosign/installation/)"
require_cmd rekor-cli "brew install rekor   (or https://docs.sigstore.dev/system_config/installation/)"
require_cmd curl      "preinstalled on macOS/Linux; otherwise your package manager"
require_cmd jq        "brew install jq      (or https://stedolan.github.io/jq/download/)"

# ---------------------------------------------------------------------
# Workdir.
# ---------------------------------------------------------------------
if [[ -n "${WORKDIR_OVERRIDE}" ]]; then
  WORKDIR="${WORKDIR_OVERRIDE}"
  mkdir -p "${WORKDIR}"
else
  WORKDIR="$(mktemp -d -t ceph-tekton-verify-build.XXXXXX)"
fi
log::info "workdir: ${WORKDIR}"

cleanup() {
  if [[ "${KEEP_WORKDIR}" -eq 1 ]]; then
    log::info "leaving workdir at ${WORKDIR} (--keep-workdir)"
    return
  fi
  # Only delete if WE created it. Don't nuke a user-supplied path.
  if [[ -z "${WORKDIR_OVERRIDE}" ]] && [[ -d "${WORKDIR}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# Detect verification mode.
#
# Rules (in order):
#   1. --type override wins.
#   2. URL ends in .deb / .rpm (case-insensitive) → PACKAGE.
#   3. URL contains @sha256: → IMAGE (digest-form OCI ref).
#   4. URL has no scheme AND looks like a registry path
#      (something/something[:tag][@digest]) → IMAGE.
#   5. Otherwise → reject with a clear error rather than guessing.
#
# Rationale: the failure modes for the wrong path are different
# (cosign verify against a .deb URL emits a confusing "manifest not
# found" error; cosign verify-blob-attestation against an OCI ref
# emits a "file not found"). Being explicit + early lets us surface
# a helpful message instead of cosign's stack trace.
# ---------------------------------------------------------------------
detect_mode() {
  local url="$1"
  if [[ -n "${TYPE_OVERRIDE}" ]]; then
    case "${TYPE_OVERRIDE}" in
      IMAGE|image)     printf 'IMAGE'   ; return ;;
      PACKAGE|package) printf 'PACKAGE' ; return ;;
      *)
        log::fail "--type must be IMAGE or PACKAGE (got '${TYPE_OVERRIDE}')"
        exit 2
        ;;
    esac
  fi
  local lower
  lower="$(printf '%s' "${url}" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    *.deb|*.rpm) printf 'PACKAGE'; return ;;
  esac
  case "${url}" in
    s3://*)
      log::fail "s3:// URLs aren't verifiable from external machines without Sepia creds."
      log::fail "  Pass the HTTPS equivalent (artifacts.ceph.com/<path>) instead, OR"
      log::fail "  force --type PACKAGE if your local mirror serves the same bytes."
      exit 2
      ;;
  esac
  case "${url}" in
    *@sha256:*)
      printf 'IMAGE'; return ;;
  esac
  # No scheme + at least one '/' before any ':' → looks like an OCI
  # ref (`registry/path:tag`). Tag-only refs are accepted by the
  # IMAGE branch but with a loud warning (cosign verifies signature
  # against bytes; a tag is a moving pointer).
  case "${url}" in
    http://*|https://*) : ;;
    */*)
      printf 'IMAGE'; return ;;
  esac
  log::fail "couldn't detect verification mode for URL: ${url}"
  log::fail "  Pass --type IMAGE or --type PACKAGE explicitly."
  exit 2
}

MODE="$(detect_mode "${ARTIFACT_URL}")"
log::info "mode=${MODE}"
log::info "artifact=${ARTIFACT_URL}"
log::info "rekor-url=${REKOR_URL}"
if [[ -n "${CERT_IDENTITY}" ]]; then
  log::info "expected cert-identity=${CERT_IDENTITY}"
else
  log::info "expected cert-identity-regexp=${CERT_IDENTITY_REGEXP}"
fi
log::info "expected cert-oidc-issuer=${CERT_OIDC_ISSUER}"

# ---------------------------------------------------------------------
# Build the shared cosign cert-flag list. Both branches use the same
# pair of flags; centralising the build keeps the keyed-vs-keyless
# decision local to here (today: keyless only).
# ---------------------------------------------------------------------
COSIGN_CERT_FLAGS=()
if [[ -n "${CERT_IDENTITY}" ]]; then
  COSIGN_CERT_FLAGS+=( --certificate-identity "${CERT_IDENTITY}" )
fi
if [[ -n "${CERT_IDENTITY_REGEXP}" ]]; then
  COSIGN_CERT_FLAGS+=( --certificate-identity-regexp "${CERT_IDENTITY_REGEXP}" )
fi
COSIGN_CERT_FLAGS+=( --certificate-oidc-issuer "${CERT_OIDC_ISSUER}" )

# ---------------------------------------------------------------------
# IMAGE branch
#
# Steps:
#   1. `cosign verify <ref>` — proves the image signature carries a
#      Fulcio cert with the expected identity AND is recorded in
#      Rekor (cosign's verify path runs the inclusion-proof
#      internally; --rekor-url pins which Rekor it asks).
#   2. `cosign verify-attestation --type slsaprovenance1 <ref>` —
#      proves the SLSA Provenance v1.0 in-toto Statement attached as
#      a cosign referrer is signed by the SAME identity.
#   3. Echo the subject digest + a `rekor-cli search --sha` so the
#      transparency-log step is visible in the script output (AC #28
#      bullet "All attestations from #26 and #27 confirmed in Rekor
#      (`rekor-cli search`)").
# ---------------------------------------------------------------------
verify_image() {
  local ref="$1"
  local sig_out="${WORKDIR}/cosign-verify.json"
  local att_out="${WORKDIR}/cosign-verify-attestation.json"

  # Tag-only refs are racy (the tag could be repointed between the
  # cosign verify and the consumer's pull). Warn but continue — the
  # caller might genuinely want to verify "whatever is at :latest"
  # for a manual audit. The Sepia publish-repo pipeline will never
  # produce a tag-only consumer URL.
  case "${ref}" in
    *@sha256:*) : ;;
    *)
      log::warn "image ref '${ref}' is not pinned to a digest — verification is racy"
      log::warn "  Pass the BY-DIGEST form (<repo>@sha256:<hex>) for a stable check."
      ;;
  esac

  log::info "[image] cosign verify ${ref}"
  if ! cosign verify \
       "${COSIGN_CERT_FLAGS[@]}" \
       --rekor-url "${REKOR_URL}" \
       --output json \
       "${ref}" >"${sig_out}" 2>"${WORKDIR}/cosign-verify.stderr"; then
    log::fail "cosign verify FAILED for ${ref}"
    log::fail "  see ${WORKDIR}/cosign-verify.stderr for cosign's diagnosis"
    cat "${WORKDIR}/cosign-verify.stderr" >&2 || true
    return 1
  fi
  log::pass "image signature verified (Fulcio identity match + Rekor inclusion proof)"

  log::info "[image] cosign verify-attestation --type slsaprovenance1 ${ref}"
  # --type slsaprovenance1 matches the predicateType Chains emits via
  # slsa/v2alpha4 (https://slsa.dev/provenance/v1). The unsuffixed
  # `slsaprovenance` alias is SLSA v0.2 and will be rejected against
  # the v1 payload — same constraint hack/e2e/lib.sh's
  # cosign_verify_envelope helper documents.
  if ! cosign verify-attestation \
       --type slsaprovenance1 \
       "${COSIGN_CERT_FLAGS[@]}" \
       --rekor-url "${REKOR_URL}" \
       --output json \
       "${ref}" >"${att_out}" 2>"${WORKDIR}/cosign-verify-attestation.stderr"; then
    log::fail "cosign verify-attestation FAILED for ${ref}"
    log::fail "  see ${WORKDIR}/cosign-verify-attestation.stderr for cosign's diagnosis"
    cat "${WORKDIR}/cosign-verify-attestation.stderr" >&2 || true
    return 1
  fi
  log::pass "SLSA Provenance v1.0 attestation verified"

  # Print the subject digest + predicateType for the operator log.
  # The attestation JSON is the DSSE envelope; .payload is base64 of
  # the in-toto Statement. Same decode path hack/e2e/lib.sh uses.
  local statement="${WORKDIR}/in-toto-statement.json"
  jq -r '.payload' "${att_out}" \
    | head -n1 \
    | base64 -d > "${statement}" 2>/dev/null || true
  if [[ -s "${statement}" ]]; then
    local subj_digest predicate_type
    subj_digest="$(jq -r '.subject[0].digest | to_entries[0] | "\(.key):\(.value)"' "${statement}" 2>/dev/null || echo "")"
    predicate_type="$(jq -r '.predicateType // empty' "${statement}" 2>/dev/null || echo "")"
    log::info "subject[0].digest=${subj_digest}"
    log::info "predicateType=${predicate_type}"
    if [[ "${predicate_type}" != "https://slsa.dev/provenance/v1" ]]; then
      log::fail "unexpected predicateType '${predicate_type}'"
      log::fail "  expected https://slsa.dev/provenance/v1 (Chains slsa/v2alpha4 format)"
      return 1
    fi
  else
    log::warn "could not decode in-toto Statement from attestation envelope"
    log::warn "  (verification already passed; this is purely diagnostic)"
  fi

  # AC #28: rekor-cli search visibility. We search by the image's
  # digest (the value cosign verify already proved is in Rekor) so a
  # hit confirms the same entry from the operator's POV.
  # Strip the optional tag part: <repo>:<tag>@sha256:<hex> → sha256:<hex>.
  local digest=""
  case "${ref}" in
    *@sha256:*) digest="${ref##*@}" ;;
  esac
  if [[ -n "${digest}" ]]; then
    rekor_search_by_sha "${digest}" || return 1
  else
    log::warn "no digest in image ref; skipping rekor-cli sha search"
    log::warn "  (cosign verify's internal Rekor check already passed above)"
  fi

  return 0
}

# ---------------------------------------------------------------------
# PACKAGE branch
#
# Steps:
#   1. Download <url> and <prefix>/attestations/<basename>.intoto.jsonl
#      with curl. The attestation path matches docs/provenance.md
#      §"Per-package SLSA attestations as S3 siblings (#27)".
#   2. `cosign verify-blob-attestation --type slsaprovenance1
#         --bundle <intoto.jsonl> --certificate-identity ...
#         --certificate-oidc-issuer ... --rekor-url ... <package>`
#      — verifies the DSSE envelope signature against the Fulcio cert
#      identity AND that the cert's Rekor entry includes the supplied
#      blob's sha256 as the attestation subject.
#   3. Compute the package's sha256 + run `rekor-cli search --sha
#      sha256:<hex>` to surface the Rekor entry to the operator log.
#
# Note on --bundle vs --signature: cosign 2.x accepts both an inline
# DSSE envelope (--signature <file containing DSSE envelope JSON>)
# and a Rekor "bundle" (--bundle <file containing signature + Rekor
# inclusion-proof JSON>). The publish-repo Task writes the file as a
# bundle (.intoto.jsonl with sigstore-bundle shape) so the verifier
# can do offline Rekor inclusion proofs. We use --bundle accordingly
# and let cosign do the right thing whether the file is a bare DSSE
# envelope or a sigstore bundle — both modes are accepted by
# --bundle in current cosign builds; --signature is the strict-DSSE
# fallback for very old bundle files.
# ---------------------------------------------------------------------
verify_package() {
  local url="$1"
  case "${url}" in
    http://*|https://*) : ;;
    *)
      log::fail "package URL must be http:// or https:// (got '${url}')"
      log::fail "  External-consumer mode: we don't fetch over s3:// or other transports."
      return 1
      ;;
  esac

  local basename="${url##*/}"
  local prefix="${url%/*}"
  local pkg_file="${WORKDIR}/${basename}"
  local att_file="${WORKDIR}/${basename}.intoto.jsonl"
  local att_url="${prefix}/attestations/${basename}.intoto.jsonl"

  log::info "[package] downloading artifact: ${url}"
  if ! curl --fail --location --silent --show-error \
       --output "${pkg_file}" "${url}"; then
    log::fail "could not download artifact from ${url}"
    return 1
  fi
  log::info "[package] downloaded artifact: ${pkg_file} ($(wc -c <"${pkg_file}") bytes)"

  log::info "[package] downloading attestation: ${att_url}"
  if ! curl --fail --location --silent --show-error \
       --output "${att_file}" "${att_url}"; then
    log::fail "could not download attestation from ${att_url}"
    log::fail "  Expected layout (see docs/provenance.md §'Per-package SLSA attestations"
    log::fail "  as S3 siblings (#27)'): <pkg-prefix>/attestations/<basename>.intoto.jsonl"
    return 1
  fi
  log::info "[package] downloaded attestation: ${att_file} ($(wc -c <"${att_file}") bytes)"

  log::info "[package] cosign verify-blob-attestation --type slsaprovenance1 ${pkg_file}"
  # --type slsaprovenance1: same SLSA v1.0 alias the IMAGE branch uses.
  # --bundle: the sibling .intoto.jsonl is a Sigstore bundle
  #   (signature + cert + Rekor entry); cosign handles offline
  #   inclusion-proof verification when --bundle is used.
  # --rekor-url: pins which Rekor instance cosign will reach IF it
  #   needs to (bundle files normally embed the proof, so the
  #   network call is a fallback for stripped bundles).
  if ! cosign verify-blob-attestation \
       --type slsaprovenance1 \
       --bundle "${att_file}" \
       "${COSIGN_CERT_FLAGS[@]}" \
       --rekor-url "${REKOR_URL}" \
       "${pkg_file}" >"${WORKDIR}/cosign-verify-blob-attestation.txt" 2>&1; then
    log::fail "cosign verify-blob-attestation FAILED"
    log::fail "  see ${WORKDIR}/cosign-verify-blob-attestation.txt for cosign's output"
    cat "${WORKDIR}/cosign-verify-blob-attestation.txt" >&2 || true
    return 1
  fi
  log::pass "SLSA Provenance v1.0 attestation verified (signature + identity + bundle inclusion)"

  # AC #28: surface the Rekor entry to the operator log explicitly.
  # We hash the package and search Rekor by that hash — the Rekor
  # entry's subject hash is what publish-repo wrote.
  local pkg_sha
  pkg_sha="sha256:$(shasum -a 256 "${pkg_file}" 2>/dev/null | awk '{print $1}')"
  if [[ "${pkg_sha}" == "sha256:" ]]; then
    # macOS shasum failed (very old / minimal install) — try sha256sum.
    pkg_sha="sha256:$(sha256sum "${pkg_file}" 2>/dev/null | awk '{print $1}')"
  fi
  if [[ "${pkg_sha}" == "sha256:" || -z "${pkg_sha##sha256:}" ]]; then
    log::warn "could not compute sha256 of package; skipping rekor-cli sha search"
    log::warn "  (cosign verify-blob-attestation already proved Rekor inclusion above)"
    return 0
  fi
  log::info "package sha256: ${pkg_sha}"
  rekor_search_by_sha "${pkg_sha}" || return 1

  return 0
}

# ---------------------------------------------------------------------
# rekor-cli search by sha — used by both branches to make the
# transparency-log step visible to the operator (AC #28 calls
# `rekor-cli search` out by name).
#
# `rekor-cli search --sha <sha>` returns the UUID(s) of any Rekor
# entry whose subject hash equals <sha>. A hit means the entry the
# upstream signer pushed to Rekor is still in the log — independent
# evidence of transparency, separate from cosign's own check.
# ---------------------------------------------------------------------
rekor_search_by_sha() {
  local sha="$1"
  local out="${WORKDIR}/rekor-search.txt"
  log::info "rekor-cli search --rekor_server ${REKOR_URL} --sha ${sha}"
  # Retry on transient public-good 5xx — same posture
  # hack/e2e/lib.sh's rekor_search helper takes.
  local attempt
  for attempt in 1 2 3; do
    if rekor-cli search \
         --rekor_server "${REKOR_URL}" \
         --sha "${sha}" >"${out}" 2>&1; then
      # rekor-cli 1.3+ prints `Found matching entries (listed by UUID):`
      # followed by ≥40-hex-char UUID lines. Pre-1.3 prints integer
      # log indexes. Accept either.
      local hits
      hits=$(grep -Ec '^([0-9]+|[0-9a-f]{40,})$' "${out}" || true)
      if [[ "${hits}" -gt 0 ]]; then
        log::pass "rekor-cli search returned ${hits} entry(ies) for ${sha}"
        sed 's/^/  /' "${out}" >&2
        return 0
      fi
    fi
    log::warn "rekor-cli search attempt ${attempt}/3: no entries, output:"
    sed 's/^/  /' "${out}" >&2 || true
    sleep $(( attempt * 3 ))
  done
  log::fail "rekor-cli search for ${sha} returned no entries after 3 attempts"
  log::fail "  This may mean the signature was never logged to Rekor (transparency"
  log::fail "  disabled at sign time), OR the wrong --rekor-url is configured."
  return 1
}

# ---------------------------------------------------------------------
# main
# ---------------------------------------------------------------------
case "${MODE}" in
  IMAGE)   verify_image   "${ARTIFACT_URL}" ;;
  PACKAGE) verify_package "${ARTIFACT_URL}" ;;
  *)
    log::fail "internal error: unknown MODE='${MODE}'"
    exit 2
    ;;
esac

log::pass "verify-build OK — ${MODE} ${ARTIFACT_URL}"

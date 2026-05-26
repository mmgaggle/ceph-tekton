#!/usr/bin/env bash
# hack/e2e/lib.sh — shared helpers for the ceph-tekton e2e assertion
# scripts. Sourced by every `hack/e2e/assert-*.sh` and by run-all.sh.
#
# Design notes:
#   * Pure bash + standard POSIX tooling (kubectl, tkn, cosign, jq,
#     syft, rekor-cli) — no Python, no Go. Anything that needs jq is
#     allowed because every assertion already depends on parsing
#     Tekton/Chains JSON output and a `jq`-less assertion would be
#     unreadable.
#   * Idempotent + safe to source multiple times — uses guarded
#     re-entry, so sourcing from run-all.sh and from an individual
#     assert-*.sh in the same shell is fine.
#   * Print-on-failure helpers capture artefacts into ${E2E_ARTIFACTS}
#     so the workflow can upload them with one `actions/upload-artifact`
#     step.

# Guard against double-source.
if [[ -n "${__CEPH_TEKTON_E2E_LIB_SOURCED:-}" ]]; then
  return 0
fi
__CEPH_TEKTON_E2E_LIB_SOURCED=1

set -euo pipefail

# ---------------------------------------------------------------------
# config — overridable from the caller's env
# ---------------------------------------------------------------------

# kind cluster + kubectl context. `make dev-up` uses ceph-tekton-dev;
# CI uses `e2e` so a contributor can run the e2e harness against an
# already-running dev cluster without colliding.
E2E_KIND_CLUSTER="${E2E_KIND_CLUSTER:-e2e}"
E2E_KUBE_CONTEXT="${E2E_KUBE_CONTEXT:-kind-${E2E_KIND_CLUSTER}}"

# Where to drop captured artefacts (logs, attestations, describe
# output). The CI workflow points this at $GITHUB_WORKSPACE/e2e-artifacts
# and uploads the directory on failure. Local runs default to a temp
# dir so devs don't have to think about it.
E2E_ARTIFACTS="${E2E_ARTIFACTS:-${TMPDIR:-/tmp}/ceph-tekton-e2e-artifacts}"
mkdir -p "${E2E_ARTIFACTS}"

# Per-assertion timeout for tkn pipeline start --showlog. Some smoke
# pipelines pull a container image as their first step; the largest is
# syft (~80MB compressed), which takes ~30s on a warm cache and up to
# ~3min cold. 600s gives Vault headroom on its slowest path too.
E2E_PIPELINERUN_TIMEOUT="${E2E_PIPELINERUN_TIMEOUT:-600s}"

# Path to the repo root. Every assert-*.sh resolves this the same way,
# but having it once in lib.sh means we don't repeat the dance.
E2E_REPO_ROOT="${E2E_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ---------------------------------------------------------------------
# pretty-printers
# ---------------------------------------------------------------------

# Used as: log::info "applying foo"
# All output goes to stderr so a script's stdout stays parseable.
log::info()  { printf '\033[1;34m[e2e] %s\033[0m\n' "$*" >&2; }
log::pass()  { printf '\033[1;32m[PASS] %s\033[0m\n' "$*" >&2; }
log::fail()  { printf '\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; }
log::warn()  { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }

# kube_ctx: invoke kubectl against the e2e cluster context.
# Wraps `kubectl --context=…` so callers don't repeat the flag and so
# we can stub it out in unit tests later.
kube_ctx() {
  kubectl --context="${E2E_KUBE_CONTEXT}" "$@"
}

# tkn_ctx: like kube_ctx but for tkn.
tkn_ctx() {
  tkn --context="${E2E_KUBE_CONTEXT}" "$@"
}

# require_cmd: assert a binary exists on PATH, abort with a clear
# install hint otherwise.
require_cmd() {
  local cmd="$1"
  local hint="${2:-see https://github.com/${cmd}}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log::fail "required tool '${cmd}' not found on PATH"
    log::fail "  install: ${hint}"
    return 1
  fi
}

# ---------------------------------------------------------------------
# PipelineRun helpers
# ---------------------------------------------------------------------

# wait_pipelinerun_succeeded NAMESPACE PIPELINERUN
#
# Block until the named PipelineRun lands in Succeeded=True OR
# Succeeded=False. Returns 0 on success, 1 on failure (and prints the
# Tekton condition message so the CI log explains why). Times out at
# ${E2E_PIPELINERUN_TIMEOUT}.
wait_pipelinerun_succeeded() {
  local ns="$1" pr="$2"
  log::info "waiting for PipelineRun ${ns}/${pr} (timeout ${E2E_PIPELINERUN_TIMEOUT})"

  # Poll the Succeeded condition. We can't just use `kubectl wait
  # --for=condition=Succeeded=True` because that would block the full
  # timeout window on a fast failure (Tekton sets Succeeded=False
  # promptly, kubectl wait would still sit there until the True wait
  # times out). Polling on a 2-second cadence is plenty for PipelineRuns
  # whose minimum wall time is the pod-pull cost (>>2s).
  #
  # We strip the trailing `s` off E2E_PIPELINERUN_TIMEOUT to get the
  # second budget, accepting integers only (the workflow always sets
  # it in seconds; documented in docs/e2e.md).
  local budget_s="${E2E_PIPELINERUN_TIMEOUT%s}"
  local elapsed=0
  local status="" reason="" message=""
  while [[ "${elapsed}" -lt "${budget_s}" ]]; do
    status="$(kube_ctx -n "${ns}" get pipelinerun "${pr}" \
                -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")"
    if [[ "${status}" == "True" || "${status}" == "False" ]]; then
      break
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
  done

  # Re-read everything for the final report (status may have been
  # empty mid-poll; reason + message only show up when status flips).
  status="$(kube_ctx -n "${ns}" get pipelinerun "${pr}" \
              -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo Unknown)"
  reason="$(kube_ctx -n "${ns}" get pipelinerun "${pr}" \
              -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || echo Unknown)"
  message="$(kube_ctx -n "${ns}" get pipelinerun "${pr}" \
               -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}' 2>/dev/null || echo '')"

  case "${status}" in
    True)
      log::info "PipelineRun ${ns}/${pr} status=True reason=${reason}"
      return 0
      ;;
    False)
      log::fail "PipelineRun ${ns}/${pr} status=False reason=${reason}"
      log::fail "  message: ${message}"
      capture_pipelinerun_artifacts "${ns}" "${pr}"
      return 1
      ;;
    *)
      log::fail "PipelineRun ${ns}/${pr} timed out (final status=${status:-Unknown})"
      capture_pipelinerun_artifacts "${ns}" "${pr}"
      return 1
      ;;
  esac
}

# start_pipelinerun NAMESPACE PIPELINE_NAME [tkn args...]
#
# Wraps `tkn pipeline start --output=name` so the caller gets back the
# PipelineRun name on stdout. All other tkn flags pass through, so
# callers can layer --param/--workspace/--serviceaccount as needed.
# Prints the run name to stdout, log lines to stderr.
start_pipelinerun() {
  local ns="$1" pipeline="$2"; shift 2
  local pr
  log::info "starting pipeline ${ns}/${pipeline}"
  # `tkn pipeline start --output=name` prints just `pipelinerun.tekton.dev/<name>`
  # to stdout — the form `kubectl wait` expects. Trim to bare name so
  # downstream callers can also use bare-name jsonpath queries.
  #
  # `--use-param-defaults` is required in non-interactive contexts: tkn
  # 0.39 still prompts for every param without an explicit `-p value=...`
  # flag, even when the Pipeline declares a default for it. In CI stdin
  # is closed; the prompt fails with "Error: EOF" and tkn emits its
  # half-rendered prompt text to stdout, which the caller then captures
  # as the "PipelineRun name". The flag tells tkn to silently use each
  # param's declared default for anything the caller didn't override.
  pr="$(tkn_ctx pipeline start "${pipeline}" -n "${ns}" \
        --output=name --use-param-defaults "$@")"
  pr="${pr##*/}"
  printf '%s\n' "${pr}"
}

# get_taskrun_for: get the most recent TaskRun belonging to a given
# pipelineTask within a PipelineRun.
get_taskrun_for() {
  local ns="$1" pr="$2" pipeline_task="$3"
  kube_ctx -n "${ns}" get taskrun \
    -l "tekton.dev/pipelineRun=${pr},tekton.dev/pipelineTask=${pipeline_task}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}'
}

# get_taskrun_result: read a single Result value off a TaskRun.
get_taskrun_result() {
  local ns="$1" tr="$2" name="$3"
  kube_ctx -n "${ns}" get taskrun "${tr}" -o json \
    | jq -r --arg n "${name}" \
        '.status.results[]? | select(.name == $n) | .value'
}

# ---------------------------------------------------------------------
# Chains / attestation helpers
# ---------------------------------------------------------------------

# decode_attestation NAMESPACE TASKRUN OUTFILE
#
# Pull the in-toto Statement attestation off a TaskRun's Chains
# annotation, base64-decode, write to OUTFILE. The annotation key is
# uid-suffixed (chains.tekton.dev/payload-taskrun-<uid>) so we glob
# for it. Returns 1 if no payload annotation is found.
decode_attestation() {
  local ns="$1" tr="$2" outfile="$3"
  local ann_key
  ann_key="$(kube_ctx -n "${ns}" get taskrun "${tr}" -o json \
              | jq -r '.metadata.annotations | keys[]? | select(startswith("chains.tekton.dev/payload-taskrun-"))' \
              | head -n1)"
  if [[ -z "${ann_key}" || "${ann_key}" == "null" ]]; then
    log::fail "no chains payload annotation on ${ns}/${tr}"
    return 1
  fi
  kube_ctx -n "${ns}" get taskrun "${tr}" -o json \
    | jq -r --arg k "${ann_key}" '.metadata.annotations[$k]' \
    | base64 -d > "${outfile}"
  log::info "decoded attestation to ${outfile} ($(wc -c <"${outfile}") bytes)"
}

# decode_envelope NAMESPACE TASKRUN OUTFILE
#
# Chains 0.26's `chains.tekton.dev/signature-taskrun-<uid>` annotation
# stores a base64-encoded DSSE envelope JSON:
#
#   { "payloadType": "application/vnd.in-toto+json",
#     "payload":     "<base64 of in-toto Statement>",
#     "signatures":  [ { "keyid": "...", "sig": "<base64 DER ECDSA>" } ] }
#
# The envelope itself is what `cosign verify-blob-attestation` expects
# as its `--signature` argument — that command handles the DSSE PAE
# reconstruction and the DER-vs-IEEE-P1363 quirk internally. Earlier
# iterations of this helper tried to extract the raw signature for
# `cosign verify-blob`; that path is fundamentally wrong for DSSE
# (raw-sig verification skips the PAE, so the signature never matches
# the payload bytes) and is replaced by the verify-blob-attestation
# helper below.
decode_envelope() {
  local ns="$1" tr="$2" outfile="$3"
  local ann_key
  ann_key="$(kube_ctx -n "${ns}" get taskrun "${tr}" -o json \
              | jq -r '.metadata.annotations | keys[]? | select(startswith("chains.tekton.dev/signature-taskrun-"))' \
              | head -n1)"
  if [[ -z "${ann_key}" || "${ann_key}" == "null" ]]; then
    log::fail "no chains signature annotation on ${ns}/${tr}"
    return 1
  fi
  kube_ctx -n "${ns}" get taskrun "${tr}" -o json \
    | jq -r --arg k "${ann_key}" '.metadata.annotations[$k]' \
    | base64 -d > "${outfile}"
  log::info "decoded DSSE envelope to ${outfile} ($(wc -c <"${outfile}") bytes)"
}

# fetch_cosign_pub OUTFILE
#
# Extract the dev cosign public key from the signing-secrets Secret
# that hack/dev-chains-setup.sh populates. Writes PEM to OUTFILE.
fetch_cosign_pub() {
  local outfile="$1"
  kube_ctx -n tekton-chains get secret signing-secrets \
    -o jsonpath='{.data.cosign\.pub}' \
    | base64 -d > "${outfile}"
  if [[ ! -s "${outfile}" ]]; then
    log::fail "tekton-chains/signing-secrets has no cosign.pub field"
    return 1
  fi
  log::info "extracted cosign.pub to ${outfile}"
}

# cosign_verify_blob KEYFILE SIGFILE PAYLOADFILE
#
# Wraps `cosign verify-blob`. Returns 0 if cosign reports Verified OK.
# Captures cosign's output to ${E2E_ARTIFACTS}/cosign-verify-blob.txt
# so a CI failure has the full message to read.
cosign_verify_envelope() {
  local keyfile="$1" envelopefile="$2" payloadfile="$3"
  local out="${E2E_ARTIFACTS}/cosign-verify-blob-attestation-$$.txt"
  log::info "cosign verify-blob-attestation (key=${keyfile##*/} envelope=${envelopefile##*/})"
  # --check-claims=false: skip the "envelope's subject digest equals the
  # supplied blob's hash" check. The assert harness already verifies the
  # subject digest in a prior step against the TaskRun's IMAGE_DIGEST
  # Result; here we only need cosign to verify the DSSE signature is
  # valid for the supplied public key. The positional blob argument is
  # still required by the CLI but its content is unused with
  # --check-claims=false; pass payloadfile so the path is unambiguous.
  # --insecure-ignore-tlog: dev Chains doesn't push to the public Rekor;
  # the rekor_search helper below verifies Rekor presence independently
  # when the cluster's transparency: rekor option is enabled.
  # `--type slsaprovenance1` (cosign's alias for SLSA Provenance v1.0,
  # predicateType `https://slsa.dev/provenance/v1`). The unsuffixed
  # `slsaprovenance` alias is SLSA v0.2; passing it against a v1 payload
  # makes cosign reject with `invalid predicate type, expected
  # slsaprovenance got https://slsa.dev/provenance/v1`. Chains 0.26's
  # slsa/v2alpha4 formatter emits v1, hence v1 here.
  if cosign verify-blob-attestation \
      --key "${keyfile}" \
      --signature "${envelopefile}" \
      --type slsaprovenance1 \
      --check-claims=false \
      --insecure-ignore-tlog \
      "${payloadfile}" >"${out}" 2>&1; then
    log::pass "cosign verify-blob-attestation OK"
    return 0
  fi
  log::fail "cosign verify-blob-attestation FAILED — see ${out}"
  cp -f "${out}" "${E2E_ARTIFACTS}/cosign-verify-blob-attestation-fail.txt" 2>/dev/null || true
  cat "${out}" >&2
  return 1
}

# rekor_search KEYFILE
#
# Run `rekor-cli search --public-key=KEYFILE --pki-format=x509` and
# assert that at least one log index is returned. Writes the raw
# output to ${E2E_ARTIFACTS}/rekor-search.txt. Returns 0 if any
# entry is found.
#
# Rekor flakiness handling: rekor-cli can return transient 5xx
# responses from the public-good instance. We retry up to 3 times
# with backoff before declaring failure.
rekor_search() {
  local keyfile="$1"
  local out="${E2E_ARTIFACTS}/rekor-search.txt"
  local attempt
  for attempt in 1 2 3; do
    log::info "rekor-cli search (attempt ${attempt}/3)"
    if rekor-cli search \
        --public-key="${keyfile}" \
        --pki-format=x509 >"${out}" 2>&1; then
      if grep -Eq '^[0-9]+$' "${out}"; then
        log::pass "rekor search returned $(grep -Ec '^[0-9]+$' "${out}") log index(es)"
        return 0
      fi
      log::warn "rekor search returned no log indexes; output:"
      cat "${out}" >&2
    fi
    sleep $(( attempt * 5 ))
  done
  log::fail "rekor search did not return any log entries after 3 attempts"
  cp -f "${out}" "${E2E_ARTIFACTS}/rekor-search-fail.txt" 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------------
# JSON-attestation field helpers
# ---------------------------------------------------------------------

# attestation_predicate_type FILE
attestation_predicate_type() {
  jq -r '.predicateType // empty' "$1"
}

# attestation_subject_digest FILE [SUBJECT_INDEX=0]
#
# Returns the sha256 digest of the chosen subject, with the
# `sha256:` prefix.
attestation_subject_digest() {
  local f="$1" idx="${2:-0}"
  jq -r --argjson i "${idx}" '
    .subject[$i].digest |
      to_entries[0] |
      "\(.key):\(.value)"
  ' "${f}"
}

# attestation_has_sbom_byproduct FILE
#
# Returns 0 if .predicate.runDetails.byproducts[] has an entry whose
# .name ends with `/sbom-ARTIFACT_OUTPUTS`, the documented landing
# slot for the chains-smoke-test SBOM type-hint Result. Logs the
# decoded content if found.
attestation_has_sbom_byproduct() {
  local f="$1"
  local hit
  hit="$(jq -r '
    .predicate.runDetails.byproducts[]?
    | select(.name | endswith("/sbom-ARTIFACT_OUTPUTS"))
    | .content
  ' "${f}" | head -n1)"
  if [[ -z "${hit}" || "${hit}" == "null" ]]; then
    log::fail "attestation has no sbom-ARTIFACT_OUTPUTS byproduct entry"
    return 1
  fi
  log::info "sbom byproduct content (decoded):"
  printf '%s' "${hit}" | base64 -d | jq . >&2
  # Assert documented shape (uri + digest + isBuildArtifact:"false").
  printf '%s' "${hit}" | base64 -d \
    | jq -e '
        (.uri | startswith("workspace://") or startswith("s3://") or startswith("oci://"))
        and (.digest | startswith("sha256:"))
        and (.isBuildArtifact == "false")
      ' >/dev/null
}

# ---------------------------------------------------------------------
# artefact capture (on failure)
# ---------------------------------------------------------------------

# capture_pipelinerun_artifacts NAMESPACE PIPELINERUN
#
# Dump everything we'd want to look at when a PipelineRun fails: the
# PipelineRun YAML, every TaskRun YAML, each TaskRun's pod logs, and
# any Chains annotations as decoded JSON. Lands under
# ${E2E_ARTIFACTS}/<pipelinerun>/.
capture_pipelinerun_artifacts() {
  local ns="$1" pr="$2"
  local dir="${E2E_ARTIFACTS}/pipelineruns/${pr}"
  mkdir -p "${dir}"
  log::warn "capturing artefacts for ${ns}/${pr} -> ${dir}"

  kube_ctx -n "${ns}" get pipelinerun "${pr}" -o yaml >"${dir}/pipelinerun.yaml" 2>&1 || true
  kube_ctx -n "${ns}" describe pipelinerun "${pr}" >"${dir}/pipelinerun.describe.txt" 2>&1 || true

  local trs
  trs="$(kube_ctx -n "${ns}" get taskrun \
          -l "tekton.dev/pipelineRun=${pr}" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  local tr
  for tr in ${trs}; do
    kube_ctx -n "${ns}" get taskrun "${tr}" -o yaml >"${dir}/taskrun-${tr}.yaml" 2>&1 || true
    tkn_ctx taskrun logs "${tr}" -n "${ns}" --all >"${dir}/taskrun-${tr}.log" 2>&1 || true
    # Decoded attestation, best-effort — failing TaskRuns may have
    # no payload annotation, that's fine.
    decode_attestation "${ns}" "${tr}" "${dir}/taskrun-${tr}.attestation.json" 2>/dev/null || true
  done
}

# capture_cluster_state — global "what's the cluster doing right now"
# snapshot, called once at the top of run-all.sh on failure.
capture_cluster_state() {
  local dir="${E2E_ARTIFACTS}/cluster"
  mkdir -p "${dir}"
  log::warn "capturing cluster state -> ${dir}"
  kube_ctx get pods -A -o wide >"${dir}/pods.txt" 2>&1 || true
  kube_ctx get events -A --sort-by=.lastTimestamp >"${dir}/events.txt" 2>&1 || true
  # Describe every non-Running pod — usually exactly the broken one.
  while IFS=$'\t' read -r pns pname pstatus; do
    [[ "${pstatus}" == "Running" || "${pstatus}" == "Completed" || "${pstatus}" == "Succeeded" ]] && continue
    kube_ctx -n "${pns}" describe pod "${pname}" \
      >"${dir}/describe-${pns}-${pname}.txt" 2>&1 || true
  done < <(kube_ctx get pods -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase 2>/dev/null \
            | awk '{printf "%s\t%s\t%s\n", $1, $2, $3}')
}

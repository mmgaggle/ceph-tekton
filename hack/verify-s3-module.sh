#!/usr/bin/env bash
# hack/verify-s3-module.sh
#
# End-to-end verification of the terraform/modules/s3-buckets module
# against a local Ceph RGW running the experimental POSIX backend
# driver (`quay.io/dparkes/zgw-posix:latest`).
#
# What this script asserts (the surface the dev env's flag matrix
# leaves enabled — see `terraform/environments/dev/main.tf`):
#
#   1. All four buckets land (dev, branch, release, grype-db).
#   2. PUT / GET works against each, both authenticated and via the
#      anonymous public-read bucket policy. This is the
#      download.ceph.com mirror path that `dnf install ceph` traverses.
#   3. Anonymous LIST is *blocked* (we only granted GetObject, not
#      ListBucket).
#
# DELIBERATELY out of scope on the dev env:
#
#   - Lifecycle expiry — `enable_lifecycle = false` here because
#     `PutBucketLifecycleConfiguration` crashes zgw-posix. Validated
#     against real RGW in `terraform/environments/dev-rgw/` instead.
#   - Versioning — `enable_versioning = false` here because
#     `PutBucketVersioning` crashes zgw-posix.
#   - Object-lock — disabled at bucket creation (it requires
#     versioning) so there's nothing to assert about retention here.
#   - PutBucketOwnershipControls / PutPublicAccessBlock — NotImplemented
#     on zgw-posix.
#
# Higher-fidelity validation of those four lives in
# `terraform/environments/dev-rgw/` against a real Ceph RGW (vstart
# on a build host, or any production-like cluster you have access to).
#
# Usage:
#   ./hack/verify-s3-module.sh                    # full cycle with teardown
#   KEEP_RUNNING=1 ./hack/verify-s3-module.sh     # skip teardown
#   SKIP_CONTAINER=1 ./hack/verify-s3-module.sh   # use already-running RGW
#
# Env knobs (all optional):
#   RGW_IMAGE          container image (default: quay.io/dparkes/zgw-posix:latest)
#   RGW_PORT           host port for the S3 API (default: 8000)
#   RGW_ACCESS_KEY     access key (default: cephtekton)
#   RGW_SECRET_KEY     secret key (default: cephtekton)
#   CONTAINER_NAME     name of the RGW container (default: ceph-tekton-zgw-posix-verify)
#   CONTAINER_ENGINE   docker | podman (default: auto-detect)
#   KEEP_RUNNING       if set, skip teardown
#   SKIP_CONTAINER     if set, the script will NOT start its own RGW —
#                      bring your own at RGW_PORT with the access keys
#                      set above. Useful for iterating against vstart
#                      or a fresh `radosgw-admin` user without paying
#                      container start cost each run.
#   SKIP_DESTROY       if set, skip `terraform destroy` (implies
#                      skipping container teardown too).

set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

RGW_IMAGE="${RGW_IMAGE:-quay.io/dparkes/zgw-posix:latest}"
RGW_PORT="${RGW_PORT:-8000}"
RGW_ACCESS_KEY="${RGW_ACCESS_KEY:-cephtekton}"
RGW_SECRET_KEY="${RGW_SECRET_KEY:-cephtekton}"
CONTAINER_NAME="${CONTAINER_NAME:-ceph-tekton-zgw-posix-verify}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_ENV_DIR="${REPO_ROOT}/terraform/environments/dev"
ENDPOINT="http://127.0.0.1:${RGW_PORT}"

# We invoke the aws CLI with these every time. Region matches the
# dev env's default (`default`, what `radosgw-admin` writes for the
# stock zonegroup).
AWS_REGION="default"
AWS_ARGS=(--endpoint-url "${ENDPOINT}" --region "${AWS_REGION}")

# Buckets — must match what terraform/environments/dev/main.tf creates.
BUCKETS=(
  ceph-artifacts-dev
  ceph-artifacts-branch
  ceph-artifacts-release
  ceph-grype-db
)

# Exit accounting — keep going through verifications, fail at the end.
FAILED=0

# --------------------------------------------------------------------------
# Pretty-printing
# --------------------------------------------------------------------------

step()    { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()      { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
warn()    { printf '  \033[1;33mWARN\033[0m %s\n' "$*"; }
fail()    { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED+1)); }
die()     { printf '\n\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------

step "Checking prerequisites"

command -v terraform >/dev/null || die "terraform not installed"
command -v aws       >/dev/null || die "aws CLI not installed"
command -v curl      >/dev/null || die "curl not installed"

if [[ -z "${SKIP_CONTAINER:-}" ]]; then
  if [[ -z "${CONTAINER_ENGINE:-}" ]]; then
    if command -v docker >/dev/null; then
      CONTAINER_ENGINE=docker
    elif command -v podman >/dev/null; then
      CONTAINER_ENGINE=podman
    else
      die "neither docker nor podman is installed; install one, set CONTAINER_ENGINE, or set SKIP_CONTAINER=1"
    fi
  fi
  command -v "${CONTAINER_ENGINE}" >/dev/null || die "${CONTAINER_ENGINE} not installed"
  ok "${CONTAINER_ENGINE} ($("${CONTAINER_ENGINE}" --version 2>&1))"
fi

ok "terraform $(terraform version | head -1)"
ok "aws $(aws --version 2>&1)"

# --------------------------------------------------------------------------
# Teardown registration (trap)
# --------------------------------------------------------------------------

teardown() {
  local rc=$?
  if [[ -n "${KEEP_RUNNING:-}" ]]; then
    step "KEEP_RUNNING set — skipping teardown"
    printf 'RGW container:   %s\n' "${CONTAINER_NAME}"
    printf 'S3 endpoint:     %s\n' "${ENDPOINT}"
    printf 'Dev terraform:   %s\n' "${DEV_ENV_DIR}"
    return $rc
  fi

  step "Tearing down"

  if [[ -z "${SKIP_DESTROY:-}" ]] && [[ -d "${DEV_ENV_DIR}/.terraform" ]]; then
    # terraform destroy needs the RGW still running, so do it first.
    if [[ -n "${SKIP_CONTAINER:-}" ]] || \
       "${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
      (cd "${DEV_ENV_DIR}" && terraform destroy -auto-approve) \
        || warn "terraform destroy failed; continuing teardown"
    else
      warn "RGW container already gone; skipping terraform destroy"
    fi
    rm -rf "${DEV_ENV_DIR}/.terraform" \
           "${DEV_ENV_DIR}/.terraform.lock.hcl" \
           "${DEV_ENV_DIR}/terraform.tfstate" \
           "${DEV_ENV_DIR}/terraform.tfstate.backup"
    ok "removed terraform state from ${DEV_ENV_DIR}"
  fi

  if [[ -z "${SKIP_CONTAINER:-}" ]] && \
     "${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    "${CONTAINER_ENGINE}" rm -f "${CONTAINER_NAME}" >/dev/null \
      && ok "removed container ${CONTAINER_NAME}" \
      || warn "failed to remove container ${CONTAINER_NAME}"
  fi

  return $rc
}
trap teardown EXIT

# --------------------------------------------------------------------------
# Start the local RGW
# --------------------------------------------------------------------------

if [[ -z "${SKIP_CONTAINER:-}" ]]; then
  step "Starting RGW (${RGW_IMAGE})"

  if "${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    warn "container ${CONTAINER_NAME} already exists — removing first"
    "${CONTAINER_ENGINE}" rm -f "${CONTAINER_NAME}" >/dev/null
  fi

  # The zgw-posix image's CLI surface is upstream-controlled. We pass
  # the access key + secret + a port via env vars and trust the image's
  # entrypoint to wire them in. If your zgw-posix tag uses a different
  # env-var shape, set CONTAINER_RUN_EXTRA="-e FOO=bar ..." to layer
  # additional flags.
  # shellcheck disable=SC2086 -- CONTAINER_RUN_EXTRA is intentionally word-split
  "${CONTAINER_ENGINE}" run -d \
    --name "${CONTAINER_NAME}" \
    -p "${RGW_PORT}:8000" \
    -e "RGW_ACCESS_KEY=${RGW_ACCESS_KEY}" \
    -e "RGW_SECRET_KEY=${RGW_SECRET_KEY}" \
    ${CONTAINER_RUN_EXTRA:-} \
    "${RGW_IMAGE}" >/dev/null

  ok "container started"
else
  step "SKIP_CONTAINER set — assuming RGW is already at ${ENDPOINT}"
fi

step "Waiting for RGW to accept S3 API requests"

# Probe the bucket-list endpoint with the configured creds. Anonymous
# probes against zgw-posix don't have a well-known health URL, so we
# just exercise the auth path directly — the response shape doesn't
# matter, only that something HTTPy comes back.
export AWS_ACCESS_KEY_ID="${RGW_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${RGW_SECRET_KEY}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

for i in $(seq 1 60); do
  if aws "${AWS_ARGS[@]}" s3api list-buckets >/dev/null 2>&1; then
    ok "ready after ${i}s"
    break
  fi
  if (( i == 60 )); then
    if [[ -z "${SKIP_CONTAINER:-}" ]]; then
      "${CONTAINER_ENGINE}" logs "${CONTAINER_NAME}" >&2 || true
    fi
    die "RGW at ${ENDPOINT} did not respond to list-buckets within 60s"
  fi
  sleep 1
done

# --------------------------------------------------------------------------
# Terraform apply
# --------------------------------------------------------------------------

step "terraform init"
(cd "${DEV_ENV_DIR}" && terraform init -input=false -no-color)
ok "init complete"

step "terraform apply"
(cd "${DEV_ENV_DIR}" && terraform apply -auto-approve -input=false -no-color)
ok "apply complete"

# --------------------------------------------------------------------------
# Verification: all four buckets exist
# --------------------------------------------------------------------------

step "Verifying all four buckets exist"

existing="$(aws "${AWS_ARGS[@]}" s3api list-buckets \
  --query 'Buckets[].Name' --output text | tr '\t' '\n')"

for b in "${BUCKETS[@]}"; do
  if printf '%s\n' "${existing}" | grep -qx "${b}"; then
    ok "bucket ${b} exists"
  else
    fail "bucket ${b} missing"
  fi
done

# --------------------------------------------------------------------------
# Public-read mirror semantics
#   For each public-read bucket: PUT a test object as the authenticated
#   admin, then GET it via plain anonymous curl (no auth headers). That
#   round-trip is exactly what `apt-get install` and `dnf install` do
#   against download.ceph.com — so passing here is the strongest signal
#   we can get on zgw-posix that the bucket policy is wired correctly.
#   We also confirm anon LIST fails (we only granted GetObject).
# --------------------------------------------------------------------------

step "Verifying public-read mirror semantics on all four buckets"

mirror_payload="public-read smoke $(date -u +%s)"
mirror_tmp="$(mktemp)"
printf '%s\n' "${mirror_payload}" > "${mirror_tmp}"
mirror_key="public-read-test-$(date -u +%s).txt"

for b in "${BUCKETS[@]}"; do
  step "  bucket ${b}"

  # PUT as authenticated admin.
  if ! aws "${AWS_ARGS[@]}" s3api put-object \
       --bucket "${b}" --key "${mirror_key}" --body "${mirror_tmp}" \
       >/dev/null 2>&1; then
    fail "could not PUT smoke object into ${b}"
    continue
  fi
  ok "PUT (authenticated)"

  # GET anonymously via curl. No AWS auth headers. Plain HTTP 200 with
  # the expected body is the success criterion.
  url="${ENDPOINT}/${b}/${mirror_key}"
  body="$(curl -fsS --max-time 10 "${url}" 2>/dev/null || echo '__FETCH_FAILED__')"
  if [[ "${body}" == "${mirror_payload}" ]]; then
    ok "GET (anonymous) returned the object — public-read works"
  else
    fail "anonymous GET of ${url} did not return the object (got: ${body:0:80})"
  fi

  # LIST should NOT be public — we only granted GetObject. Use curl on
  # the bucket root; expect anything that isn't a 200 with a valid XML
  # listing.
  list_status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${ENDPOINT}/${b}/" || echo 000)"
  if [[ "${list_status}" == "200" ]]; then
    fail "anonymous LIST of ${b} returned 200 — policy should grant GetObject only"
  else
    ok "anonymous LIST blocked (HTTP ${list_status})"
  fi

  # Clean up so terraform destroy doesn't trip over a non-empty bucket
  # (force_destroy = true means it COULD reap the object, but emptying
  # explicitly keeps the teardown path narrow).
  aws "${AWS_ARGS[@]}" s3api delete-object \
    --bucket "${b}" --key "${mirror_key}" >/dev/null 2>&1 || true
done

rm -f "${mirror_tmp}"

# --------------------------------------------------------------------------
# Result
# --------------------------------------------------------------------------

step "Summary"

if (( FAILED > 0 )); then
  printf '\n\033[1;31m%d verification(s) FAILED\033[0m\n' "${FAILED}"
  exit 1
fi

printf '\n\033[1;32mAll verifications passed.\033[0m\n'
printf '\nFor versioning + lifecycle + object-lock coverage, run\n'
printf 'terraform/environments/dev-rgw/ against a real Ceph RGW.\n'
exit 0

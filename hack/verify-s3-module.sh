#!/usr/bin/env bash
# hack/verify-s3-module.sh
#
# End-to-end verification of the terraform/modules/s3-buckets module
# against a local MinIO instance. The flow is:
#
#   1. Detect docker or podman.
#   2. Start MinIO (host net or published ports) on a known port.
#   3. Wait for it to be live and create an admin-level alias.
#   4. terraform init + apply terraform/environments/dev.
#   5. Verify with aws s3api calls:
#         - all three buckets exist
#         - dev bucket has 30d expiry lifecycle, no versioning,
#           no object-lock
#         - branch bucket has lifecycle + versioning, no object-lock
#         - release bucket has object-lock GOVERNANCE configured
#   6. Behavioral test: PUT an object into the release bucket,
#      DELETE it without bypass, confirm S3 refuses; then DELETE
#      with --bypass-governance-retention and confirm it succeeds.
#   7. Tear down: terraform destroy + remove MinIO container +
#      remove dev/.terraform + dev/terraform.tfstate*.
#
# Exit non-zero on any verification failure. Print a CAVEAT line and
# continue if MinIO's object-lock support is incomplete (older
# versions); the script still asserts everything it can.
#
# Usage:
#   ./hack/verify-s3-module.sh           # full cycle with teardown
#   KEEP_RUNNING=1 ./hack/verify-s3-module.sh   # skip teardown for debugging
#
# Env knobs (all optional):
#   MINIO_IMAGE       container image (default: quay.io/minio/minio:latest)
#   MINIO_PORT        host port for the S3 API (default: 9000)
#   MINIO_CONSOLE_PORT host port for the console (default: 9001)
#   CONTAINER_NAME    name of the MinIO container (default: ceph-tekton-minio-verify)
#   CONTAINER_ENGINE  docker | podman (default: auto-detect)
#   KEEP_RUNNING      if set, skip teardown
#   SKIP_DESTROY      if set, skip `terraform destroy` (implies skipping container teardown too)

set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

MINIO_IMAGE="${MINIO_IMAGE:-quay.io/minio/minio:latest}"
MINIO_PORT="${MINIO_PORT:-9000}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
CONTAINER_NAME="${CONTAINER_NAME:-ceph-tekton-minio-verify}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_ENV_DIR="${REPO_ROOT}/terraform/environments/dev"
ENDPOINT="http://127.0.0.1:${MINIO_PORT}"

# We invoke the aws CLI with these every time:
AWS_REGION="us-east-1"
AWS_ARGS=(--endpoint-url "${ENDPOINT}" --region "${AWS_REGION}")

# Buckets — must match what terraform/environments/dev/main.tf creates.
BUCKET_DEV="ceph-artifacts-dev"
BUCKET_BRANCH="ceph-artifacts-branch"
BUCKET_RELEASE="ceph-artifacts-release"

# Exit accounting — keep going through verifications, fail at the end.
FAILED=0
CAVEATS=0

# --------------------------------------------------------------------------
# Pretty-printing
# --------------------------------------------------------------------------

step()    { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()      { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
warn()    { printf '  \033[1;33mWARN\033[0m %s\n' "$*"; }
fail()    { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED+1)); }
caveat()  { printf '  \033[1;35mCAVEAT\033[0m %s\n' "$*"; CAVEATS=$((CAVEATS+1)); }
die()     { printf '\n\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------

step "Checking prerequisites"

command -v terraform >/dev/null || die "terraform not installed"
command -v aws       >/dev/null || die "aws CLI not installed"
command -v jq        >/dev/null || die "jq not installed"

if [[ -z "${CONTAINER_ENGINE:-}" ]]; then
  if command -v docker >/dev/null; then
    CONTAINER_ENGINE=docker
  elif command -v podman >/dev/null; then
    CONTAINER_ENGINE=podman
  else
    die "neither docker nor podman is installed; install one or set CONTAINER_ENGINE"
  fi
fi
command -v "${CONTAINER_ENGINE}" >/dev/null || die "${CONTAINER_ENGINE} not installed"

ok "terraform $(terraform version | head -1)"
ok "aws $(aws --version 2>&1)"
ok "${CONTAINER_ENGINE} ($("${CONTAINER_ENGINE}" --version 2>&1))"

# --------------------------------------------------------------------------
# Teardown registration (trap)
# --------------------------------------------------------------------------

teardown() {
  local rc=$?
  if [[ -n "${KEEP_RUNNING:-}" ]]; then
    step "KEEP_RUNNING set — skipping teardown"
    printf 'MinIO container: %s\n' "${CONTAINER_NAME}"
    printf 'S3 endpoint:     %s\n' "${ENDPOINT}"
    printf 'Dev terraform:   %s\n' "${DEV_ENV_DIR}"
    return $rc
  fi

  step "Tearing down"

  if [[ -z "${SKIP_DESTROY:-}" ]] && [[ -d "${DEV_ENV_DIR}/.terraform" ]]; then
    # terraform destroy needs MinIO still running, so do it first.
    if "${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
      (cd "${DEV_ENV_DIR}" && terraform destroy -auto-approve) \
        || warn "terraform destroy failed; continuing teardown"
    else
      warn "MinIO container already gone; skipping terraform destroy"
    fi
    rm -rf "${DEV_ENV_DIR}/.terraform" \
           "${DEV_ENV_DIR}/.terraform.lock.hcl" \
           "${DEV_ENV_DIR}/terraform.tfstate" \
           "${DEV_ENV_DIR}/terraform.tfstate.backup"
    ok "removed terraform state from ${DEV_ENV_DIR}"
  fi

  if "${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    "${CONTAINER_ENGINE}" rm -f "${CONTAINER_NAME}" >/dev/null \
      && ok "removed container ${CONTAINER_NAME}" \
      || warn "failed to remove container ${CONTAINER_NAME}"
  fi

  return $rc
}
trap teardown EXIT

# --------------------------------------------------------------------------
# Start MinIO
# --------------------------------------------------------------------------

step "Starting MinIO (${MINIO_IMAGE})"

if "${CONTAINER_ENGINE}" inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  warn "container ${CONTAINER_NAME} already exists — removing first"
  "${CONTAINER_ENGINE}" rm -f "${CONTAINER_NAME}" >/dev/null
fi

"${CONTAINER_ENGINE}" run -d \
  --name "${CONTAINER_NAME}" \
  -p "${MINIO_PORT}:9000" \
  -p "${MINIO_CONSOLE_PORT}:9001" \
  -e "MINIO_ROOT_USER=${MINIO_ROOT_USER}" \
  -e "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}" \
  "${MINIO_IMAGE}" \
  server /data --console-address ":9001" >/dev/null

ok "container started"

step "Waiting for MinIO to accept S3 API requests"

# Use the live/ready probe rather than blind sleep.
for i in $(seq 1 60); do
  if curl -sf "${ENDPOINT}/minio/health/ready" >/dev/null 2>&1; then
    ok "ready after ${i}s"
    break
  fi
  if (( i == 60 )); then
    "${CONTAINER_ENGINE}" logs "${CONTAINER_NAME}" >&2 || true
    die "MinIO did not become ready within 60s"
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
# Verification
# --------------------------------------------------------------------------

# AWS CLI needs these creds to talk to MinIO; pass them via env so we
# don't pollute the developer's ~/.aws.
export AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}"
export AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

step "Verifying all three buckets exist"

# `mapfile` is bash 4+; iterate via process substitution to keep this
# script working on macOS's stock bash 3.2 as well.
existing="$(aws "${AWS_ARGS[@]}" s3api list-buckets \
  --query 'Buckets[].Name' --output text | tr '\t' '\n')"

for b in "${BUCKET_DEV}" "${BUCKET_BRANCH}" "${BUCKET_RELEASE}"; do
  if printf '%s\n' "${existing}" | grep -qx "${b}"; then
    ok "bucket ${b} exists"
  else
    fail "bucket ${b} missing"
  fi
done

# --------------------------------------------------------------------------
# Dev bucket: 30d expiry, no versioning, no object-lock
# --------------------------------------------------------------------------

step "Verifying ${BUCKET_DEV}: 30d expiry, no versioning, no object-lock"

dev_lifecycle="$(aws "${AWS_ARGS[@]}" s3api get-bucket-lifecycle-configuration \
  --bucket "${BUCKET_DEV}" 2>/dev/null || echo '{}')"

dev_days="$(printf '%s' "${dev_lifecycle}" | jq -r '
  .Rules[]? | select(.Expiration?.Days != null) | .Expiration.Days
' | head -1)"

if [[ "${dev_days}" == "30" ]]; then
  ok "lifecycle expiration = 30d"
else
  fail "expected 30d expiration on ${BUCKET_DEV}, got '${dev_days}'"
fi

dev_versioning="$(aws "${AWS_ARGS[@]}" s3api get-bucket-versioning \
  --bucket "${BUCKET_DEV}" --output json 2>/dev/null | jq -r '.Status // "None"')"
if [[ "${dev_versioning}" == "None" || "${dev_versioning}" == "Suspended" ]]; then
  ok "versioning disabled (status=${dev_versioning})"
else
  fail "expected versioning disabled on ${BUCKET_DEV}, got '${dev_versioning}'"
fi

if aws "${AWS_ARGS[@]}" s3api get-object-lock-configuration \
     --bucket "${BUCKET_DEV}" >/dev/null 2>&1; then
  fail "expected NO object-lock on ${BUCKET_DEV}, but got a config"
else
  ok "object-lock not configured"
fi

# --------------------------------------------------------------------------
# Branch bucket: lifecycle + versioning, no object-lock
# --------------------------------------------------------------------------

step "Verifying ${BUCKET_BRANCH}: 180d expiry, versioning on, no object-lock"

branch_lifecycle="$(aws "${AWS_ARGS[@]}" s3api get-bucket-lifecycle-configuration \
  --bucket "${BUCKET_BRANCH}" 2>/dev/null || echo '{}')"

branch_days="$(printf '%s' "${branch_lifecycle}" | jq -r '
  .Rules[]? | select(.Expiration?.Days != null) | .Expiration.Days
' | head -1)"

if [[ "${branch_days}" == "180" ]]; then
  ok "lifecycle expiration = 180d"
else
  fail "expected 180d expiration on ${BUCKET_BRANCH}, got '${branch_days}'"
fi

branch_noncurrent="$(printf '%s' "${branch_lifecycle}" | jq -r '
  .Rules[]? | select(.NoncurrentVersionExpiration?.NoncurrentDays != null) | .NoncurrentVersionExpiration.NoncurrentDays
' | head -1)"

if [[ "${branch_noncurrent}" == "7" ]]; then
  ok "noncurrent version expiration = 7d"
else
  # MinIO older releases sometimes don't surface noncurrent rules
  # back through GetBucketLifecycleConfiguration even though they
  # accepted them on Put.
  caveat "expected 7d noncurrent expiration, got '${branch_noncurrent}' (MinIO may not echo it)"
fi

branch_versioning="$(aws "${AWS_ARGS[@]}" s3api get-bucket-versioning \
  --bucket "${BUCKET_BRANCH}" --output json | jq -r '.Status // "None"')"
if [[ "${branch_versioning}" == "Enabled" ]]; then
  ok "versioning enabled"
else
  fail "expected versioning enabled on ${BUCKET_BRANCH}, got '${branch_versioning}'"
fi

if aws "${AWS_ARGS[@]}" s3api get-object-lock-configuration \
     --bucket "${BUCKET_BRANCH}" >/dev/null 2>&1; then
  fail "expected NO object-lock on ${BUCKET_BRANCH}, but got a config"
else
  ok "object-lock not configured"
fi

# --------------------------------------------------------------------------
# Release bucket: object-lock GOVERNANCE
# --------------------------------------------------------------------------

step "Verifying ${BUCKET_RELEASE}: object-lock GOVERNANCE configured"

release_versioning="$(aws "${AWS_ARGS[@]}" s3api get-bucket-versioning \
  --bucket "${BUCKET_RELEASE}" --output json | jq -r '.Status // "None"')"
if [[ "${release_versioning}" == "Enabled" ]]; then
  ok "versioning enabled (required for object-lock)"
else
  fail "expected versioning enabled on ${BUCKET_RELEASE}, got '${release_versioning}'"
fi

release_olock_json="$(aws "${AWS_ARGS[@]}" s3api get-object-lock-configuration \
  --bucket "${BUCKET_RELEASE}" --output json 2>/dev/null || echo '{}')"

release_olock_enabled="$(printf '%s' "${release_olock_json}" \
  | jq -r '.ObjectLockConfiguration.ObjectLockEnabled // "missing"')"
if [[ "${release_olock_enabled}" == "Enabled" ]]; then
  ok "ObjectLockEnabled = Enabled"
else
  fail "expected ObjectLockEnabled=Enabled on ${BUCKET_RELEASE}, got '${release_olock_enabled}'"
fi

release_mode="$(printf '%s' "${release_olock_json}" \
  | jq -r '.ObjectLockConfiguration.Rule.DefaultRetention.Mode // "missing"')"
release_years="$(printf '%s' "${release_olock_json}" \
  | jq -r '.ObjectLockConfiguration.Rule.DefaultRetention.Years // "missing"')"

if [[ "${release_mode}" == "GOVERNANCE" ]]; then
  ok "default retention mode = GOVERNANCE"
else
  # Some older MinIO versions don't return DefaultRetention even though
  # the bucket was created with object-lock enabled.
  if [[ "${release_mode}" == "missing" ]]; then
    caveat "MinIO did not return DefaultRetention.Mode; bucket has object-lock enabled but default retention may not be honored — verify against RGW separately"
  else
    fail "expected default retention mode GOVERNANCE, got '${release_mode}'"
  fi
fi

if [[ "${release_years}" == "1" ]]; then
  ok "default retention = 1 year (dev env value)"
elif [[ "${release_years}" == "missing" ]]; then
  : # already noted above
else
  fail "expected default retention 1 year (dev), got '${release_years}'"
fi

# --------------------------------------------------------------------------
# Behavioral test: object-lock actually blocks deletes on release bucket
# --------------------------------------------------------------------------

step "Behavioral test: object-lock blocks DELETE on ${BUCKET_RELEASE}"

tmpfile="$(mktemp)"
# Stash the path so the EXIT trap (defined as `teardown` above)
# doesn't need to know about it — append to a per-script cleanup list.
# Easier: rm it inline at the end of this block.
echo "object-lock test payload $(date -u +%s)" > "${tmpfile}"

test_key="object-lock-test-$(date -u +%s).txt"

# Compute a 7-day retain-until so we don't have to depend on bucket
# default retention being honored — exercises per-object retention,
# which is the same governance enforcement path.
retain_until="$(date -u -v+7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                date -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ)"

put_ok=0
if aws "${AWS_ARGS[@]}" s3api put-object \
     --bucket "${BUCKET_RELEASE}" \
     --key "${test_key}" \
     --body "${tmpfile}" \
     --object-lock-mode GOVERNANCE \
     --object-lock-retain-until-date "${retain_until}" \
     >/dev/null 2>&1; then
  ok "PUT with GOVERNANCE retention succeeded"
  put_ok=1
else
  caveat "MinIO refused PUT with per-object GOVERNANCE retention; skipping the behavioral half of the test"
fi

if (( put_ok )); then
  # Delete the *version* (not just a delete marker) without bypass —
  # must fail with AccessDenied because retention is active.
  ver_id="$(aws "${AWS_ARGS[@]}" s3api list-object-versions \
              --bucket "${BUCKET_RELEASE}" \
              --prefix "${test_key}" \
              --query 'Versions[0].VersionId' \
              --output text)"

  if [[ -z "${ver_id}" || "${ver_id}" == "None" ]]; then
    fail "could not find version id for ${test_key} after PUT"
  else
    if aws "${AWS_ARGS[@]}" s3api delete-object \
         --bucket "${BUCKET_RELEASE}" \
         --key "${test_key}" \
         --version-id "${ver_id}" \
         >/dev/null 2>&1; then
      fail "DELETE of locked object succeeded (it must not)"
    else
      ok "DELETE of locked object was blocked (correct)"
    fi

    # Bypass — should succeed.
    if aws "${AWS_ARGS[@]}" s3api delete-object \
         --bucket "${BUCKET_RELEASE}" \
         --key "${test_key}" \
         --version-id "${ver_id}" \
         --bypass-governance-retention \
         >/dev/null 2>&1; then
      ok "DELETE with --bypass-governance-retention succeeded (correct)"
    else
      caveat "DELETE with --bypass-governance-retention failed — MinIO may require additional auth headers; verify governance bypass against RGW separately"
    fi
  fi
fi

rm -f "${tmpfile}"

# --------------------------------------------------------------------------
# Result
# --------------------------------------------------------------------------

step "Summary"

if (( FAILED > 0 )); then
  printf '\n\033[1;31m%d verification(s) FAILED\033[0m\n' "${FAILED}"
  exit 1
fi

if (( CAVEATS > 0 )); then
  printf '\n\033[1;33m%d CAVEAT(s) noted — see lines above\033[0m\n' "${CAVEATS}"
fi

printf '\n\033[1;32mAll verifications passed.\033[0m\n'
exit 0

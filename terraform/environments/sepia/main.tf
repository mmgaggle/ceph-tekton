# ---------------------------------------------------------------------------
# Sepia environment — STUB.
#
# Documented, not applied. Do not `terraform apply` from this directory
# without explicit human sign-off; the Sepia RGW endpoint, credentials,
# and state backend must all be configured first. See `versions.tf`
# for the state-backend setup and `terraform/README.md` §"Sepia env"
# for the apply runbook.
#
# The same `s3-buckets` module is used unchanged — Sepia just gets
# production-grade values for retention and AWS-style hardening turned
# on (Ceph RGW Squid+ implements PutPublicAccessBlock and
# PutBucketOwnershipControls).
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.rgw_region

  # Auth via a standard AWS credentials file (`~/.aws/credentials` by
  # default) keyed by a named profile. Once the RGW OIDC trust + role
  # from issue #7 lands, this is replaced by `AssumeRoleWithWebIdentity`
  # from a CI SA token and the long-lived bootstrap profile goes away.
  # pathexpand() so the `~/.aws/credentials` default resolves the
  # tilde.
  shared_credentials_files = [pathexpand(var.credentials_path)]
  profile                  = var.credentials_profile

  skip_credentials_validation = true # RGW STS surface differs from AWS
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    s3 = var.rgw_endpoint
  }
}

module "artifacts" {
  source = "../../modules/s3-buckets"

  dev_bucket_name      = "ceph-artifacts-dev"
  branch_bucket_name   = "ceph-artifacts-branch"
  release_bucket_name  = "ceph-artifacts-release"
  grype_db_bucket_name = "ceph-grype-db"
  events_bucket_name   = "ceph-tekton-events"

  dev_expiration_days                       = 30
  branch_expiration_days                    = 180
  branch_noncurrent_version_expiration_days = 7
  grype_db_expiration_days                  = 30
  # 0 = never expire. Long-window trend queries (build success rate by
  # branch over the release cycle, queue-time trend across the year)
  # want as much history as we can afford. Override here if Sepia
  # storage budget tightens.
  events_expiration_days    = 0
  release_object_lock_mode  = "GOVERNANCE"
  release_object_lock_years = 7

  # NEVER true in Sepia — release bucket holds signed artifacts with
  # multi-year retention; dev/branch buckets hold things the broader
  # Ceph community pulls from.
  force_destroy = false

  # Ceph RGW Squid+ implements both. Verify against the live Sepia RGW
  # version before applying; older RGW returns NotImplemented and
  # `terraform apply` will fail at the corresponding resource.
  enable_public_access_block       = true
  enable_bucket_ownership_controls = true

  # All four buckets are public-readable. Ceph users + teuthology fetch
  # via plain HTTP from `artifacts.ceph.com/<bucket>/...`; the grype-db
  # bucket is consumed by every vuln-scan TaskRun across all clusters.
  # Authenticated writes still gate on the STS roles (#7, #8).
  # Object-lock on the release bucket is orthogonal — read open,
  # write/delete restricted.
  dev_public_read      = true
  branch_public_read   = true
  release_public_read  = true
  grype_db_public_read = true

  # Default `["*"]` exposes the entire bucket. Override here to keep
  # any internal `staging/` prefix private during publish-repo atomic
  # swap (#21). Add prefixes once the layout under each bucket is
  # finalized.
  # public_read_prefixes = ["repodata/*", "packages/*", "dists/*", "pubkey.gpg"]

  tags = {
    project = "ceph-tekton"
    env     = "sepia"
    owner   = "ceph-infra"
  }
}

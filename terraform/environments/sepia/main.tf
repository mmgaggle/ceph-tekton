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
  region                      = var.rgw_region
  access_key                  = var.rgw_access_key
  secret_key                  = var.rgw_secret_key

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

  dev_bucket_name     = "ceph-artifacts-dev"
  branch_bucket_name  = "ceph-artifacts-branch"
  release_bucket_name = "ceph-artifacts-release"

  dev_expiration_days                       = 30
  branch_expiration_days                    = 180
  branch_noncurrent_version_expiration_days = 7
  release_object_lock_mode                  = "GOVERNANCE"
  release_object_lock_years                 = 7

  # NEVER true in Sepia — release bucket holds signed artifacts with
  # multi-year retention; dev/branch buckets hold things the broader
  # Ceph community pulls from.
  force_destroy = false

  # Confirm RGW version implements these before flipping to true.
  enable_public_access_block       = false
  enable_bucket_ownership_controls = false

  tags = {
    project = "ceph-tekton"
    env     = "sepia"
    owner   = "ceph-infra"
  }
}

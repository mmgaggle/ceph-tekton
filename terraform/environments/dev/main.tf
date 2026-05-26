# ---------------------------------------------------------------------------
# Dev environment — points the AWS provider at a local MinIO endpoint.
#
# Why the AWS provider (not aminueza/minio): see
# `terraform/modules/s3-buckets/README.md` §"Why the AWS provider".
# Short version: MinIO and RGW both implement the S3 API; using one
# provider for all three backends (AWS, MinIO, RGW) means the dev
# `apply` exercises the same resource graph that runs against Sepia.
# ---------------------------------------------------------------------------

provider "aws" {
  region     = var.minio_region
  access_key = var.minio_access_key
  secret_key = var.minio_secret_key

  # MinIO-friendly knobs.
  skip_credentials_validation = true # MinIO has no STS GetCallerIdentity
  skip_metadata_api_check     = true # don't try to hit the IMDS
  skip_requesting_account_id  = true # MinIO has no account-id concept
  s3_use_path_style           = true # MinIO needs path-style URLs

  endpoints {
    s3 = var.minio_endpoint
    # sts/iam endpoints are not used by this module; if they ever are,
    # they'd need to be pointed somewhere too.
  }
}

module "artifacts" {
  source = "../../modules/s3-buckets"

  dev_bucket_name      = "${var.bucket_prefix}ceph-artifacts-dev"
  branch_bucket_name   = "${var.bucket_prefix}ceph-artifacts-branch"
  release_bucket_name  = "${var.bucket_prefix}ceph-artifacts-release"
  grype_db_bucket_name = "${var.bucket_prefix}ceph-grype-db"

  # Dev defaults: short retention so the local MinIO doesn't keep
  # growing; force_destroy true so `terraform destroy` works for an
  # ephemeral environment. Release bucket still keeps the smallest
  # legal object-lock retention (1y) — MinIO refuses 0.
  dev_expiration_days       = 30
  branch_expiration_days    = 180
  grype_db_expiration_days  = 30
  release_object_lock_mode  = "GOVERNANCE"
  release_object_lock_years = 1

  force_destroy = true

  # MinIO doesn't implement these AWS-only sub-APIs.
  enable_public_access_block       = false
  enable_bucket_ownership_controls = false

  # Mirror semantics on, same as Sepia. The verify script confirms
  # anonymous curl against MinIO works once the public bucket policy
  # lands. MinIO supports public bucket policies natively — no
  # public-access-block plumbing needed.
  dev_public_read      = true
  branch_public_read   = true
  release_public_read  = true
  grype_db_public_read = true

  tags = {
    project = "ceph-tekton"
    env     = "dev"
    owner   = "local"
  }
}

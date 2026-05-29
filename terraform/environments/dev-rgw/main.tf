# ---------------------------------------------------------------------------
# dev-rgw — applies the s3-buckets module against a real Ceph RGW test
# user's account. Bridges between the `dev` env (zgw-posix — RGW with
# the experimental POSIX backend driver; versioning + lifecycle still
# crash the gateway there) and the `sepia` production stub (no apply
# allowed).
#
# Use this env when you have a test user on a real Ceph cluster and
# want to verify:
#   - lifecycle rules are honored (RGW's lifecycle scanner actually runs)
#   - object-lock retains across the real chain (versioning + retention
#     metadata + DELETE rejection)
#   - public bucket policies expose objects to anonymous curl
#   - bucket-ownership-controls / public-access-block (Squid+ only) work
#
# The `bucket_prefix` variable namespaces the resources, so multiple
# developers can point this env at the same RGW.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.rgw_region

  # Auth via a standard AWS credentials file (`~/.aws/credentials` by
  # default) keyed by a named profile. Keeps long-lived test-user
  # keys out of shell env / history; profile-per-cluster makes
  # juggling several Ceph endpoints natural. pathexpand() so the
  # `~/.aws/credentials` default resolves the tilde.
  shared_credentials_files = [pathexpand(var.credentials_path)]
  profile                  = var.credentials_profile

  # RGW STS / IAM surfaces differ from AWS — skip the validations
  # that would otherwise hit unsupported endpoints.
  skip_credentials_validation = true
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

  # bucket_prefix namespaces every bucket so devs don't collide.
  dev_bucket_name      = "${var.bucket_prefix}ceph-artifacts-dev"
  branch_bucket_name   = "${var.bucket_prefix}ceph-artifacts-branch"
  release_bucket_name  = "${var.bucket_prefix}ceph-artifacts-release"
  grype_db_bucket_name = "${var.bucket_prefix}ceph-grype-db"
  events_bucket_name   = "${var.bucket_prefix}ceph-tekton-events"
  sccache_bucket_name  = "${var.bucket_prefix}ceph-builder-cache"

  # Short retention windows make test cycles cheap. The release bucket
  # keeps the minimum legal object-lock retention (1y on RGW; bumpable
  # via the variable for longer-window testing). Events bucket: keep
  # 30d in dev-rgw so test cycles don't accumulate gigabytes of
  # PipelineRun JSONL — Sepia's "never expire" posture is a separate
  # apply with that env's storage budget.
  dev_expiration_days       = 30
  branch_expiration_days    = 180
  grype_db_expiration_days  = 30
  events_expiration_days    = 30
  sccache_expiration_days   = 30
  release_object_lock_mode  = "GOVERNANCE"
  release_object_lock_years = var.release_object_lock_years

  # Dev test scope — let teardown remove buckets with objects in
  # them. (Object-lock still blocks deletes on the release bucket
  # until retention expires or `--bypass-governance-retention` is
  # used.)
  force_destroy = true

  # Ceph RGW Squid+ implements both. Older RGW returns NotImplemented;
  # flip these to false if your test cluster runs an earlier version.
  enable_public_access_block       = true
  enable_bucket_ownership_controls = true

  # Lifecycle is intentionally OFF for dev-rgw until RGW's
  # GetBucketLifecycleConfiguration handler stops downgrading the V2
  # `<Filter></Filter>` shape to legacy V1 `<Prefix></Prefix>`. The AWS
  # provider 5.x can't converge its post-PUT consistency wait against
  # the downgraded GET. See notes/rgw-lifecycle-empty-filter-v1-downgrade.md
  # for the reproducer; flip back to true once RGW is fixed.
  enable_lifecycle = false

  # Mirror semantics: validate that public bucket policies actually
  # let anonymous curl through. The Sepia env has the same flags.
  dev_public_read      = true
  branch_public_read   = true
  release_public_read  = true
  grype_db_public_read = true

  tags = {
    project = "ceph-tekton"
    env     = "dev-rgw"
    owner   = var.bucket_prefix
  }
}

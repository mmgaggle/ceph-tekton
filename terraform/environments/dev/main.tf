# ---------------------------------------------------------------------------
# Dev environment — points the AWS provider at a local Ceph RGW running
# against the POSIX backend driver (`quay.io/dparkes/zgw-posix:latest`).
#
# Why zgw-posix as the dev backend:
#   - It IS the Ceph RGW codebase, just with a POSIX filesystem driver
#     instead of the production OSD backend. The S3 API surface a
#     contributor exercises locally is the same code that runs on
#     Sepia — bugs caught here are real bugs, not stand-in artefacts.
#   - It's one container, no cluster setup. `quay.io/dparkes/zgw-posix`
#     starts in seconds against a host-mounted directory; the
#     hack/verify-s3-module.sh script drives the lifecycle.
#
# What zgw-posix can't do (yet):
#   - `PutBucketVersioning` crashes the gateway (driver is explicitly
#     experimental). The dev env therefore sets
#     `enable_versioning = false` on the s3-buckets module, which
#     also disables object-lock on the release bucket (object-lock
#     requires versioning). Higher-fidelity validation of the
#     versioning + object-lock paths is the dev-rgw env's job —
#     either against vstart RGW on a build host, or against any
#     real Ceph cluster a contributor has access to.
#   - Lifecycle calls likewise crash the gateway, so
#     `enable_lifecycle = false` here too. (Same flag we already use
#     in dev-rgw for a different reason — see ceph-tekton issue #57.)
#   - The AWS-only sub-APIs (PutBucketOwnershipControls,
#     PutPublicAccessBlock) aren't implemented; left off here.
#
# What stays exercised:
#   - Bucket creation (all four buckets land).
#   - Object PUT / GET / DELETE.
#   - Public-read bucket policies — anonymous curl works against
#     `dev`, `branch`, `release`, and `grype-db`. This is the
#     download.ceph.com mirror-semantics path; verifying it locally
#     against the same RGW code that runs in production is the main
#     point of using zgw-posix over a fake S3.
# ---------------------------------------------------------------------------

provider "aws" {
  region     = var.rgw_region
  access_key = var.rgw_access_key
  secret_key = var.rgw_secret_key

  # RGW STS / IAM endpoints differ from AWS — skip the validations
  # the provider would otherwise run against unsupported endpoints.
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

  dev_bucket_name      = "${var.bucket_prefix}ceph-artifacts-dev"
  branch_bucket_name   = "${var.bucket_prefix}ceph-artifacts-branch"
  release_bucket_name  = "${var.bucket_prefix}ceph-artifacts-release"
  grype_db_bucket_name = "${var.bucket_prefix}ceph-grype-db"
  events_bucket_name   = "${var.bucket_prefix}ceph-tekton-events"

  # Dev defaults: force_destroy true so `terraform destroy` works
  # cleanly for an ephemeral environment. The release-bucket
  # object-lock years value is moot here — object-lock isn't
  # configured at all when enable_versioning = false (see below) —
  # but we set it to 1 so the variable still has a legal value.
  dev_expiration_days      = 30
  branch_expiration_days   = 180
  grype_db_expiration_days = 30
  # 0 = never expire. Mirrors the Sepia posture; events_expiration is
  # a moot value here anyway because enable_lifecycle = false below
  # (zgw-posix can't service lifecycle calls).
  events_expiration_days    = 0
  release_object_lock_mode  = "GOVERNANCE"
  release_object_lock_years = 1

  force_destroy = true

  # zgw-posix limitations — see header. Versioning + lifecycle calls
  # crash the gateway; the AWS-only ownership/PAB sub-APIs are
  # NotImplemented. The dev env validates what zgw-posix CAN do
  # (bucket create, PUT/GET, public-read policy) and explicitly
  # defers everything else to the dev-rgw env.
  enable_versioning                = false
  enable_lifecycle                 = false
  enable_public_access_block       = false
  enable_bucket_ownership_controls = false

  # Mirror semantics on, same as Sepia. The verify script confirms
  # anonymous curl against zgw-posix returns the published bytes —
  # the same path `dnf install ceph` traverses against the
  # production download.ceph.com mirror.
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

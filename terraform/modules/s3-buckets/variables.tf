# ---------------------------------------------------------------------------
# Per-bucket inputs
#
# The module creates the four buckets ceph-tekton needs (dev / branch /
# release / grype-db). Bucket *names* are inputs so the same module can
# be pointed at any S3-compatible backend (zgw-posix for local dev, real
# Ceph RGW for dev-rgw + Sepia, AWS S3 for parity testing) with
# namespace conventions chosen per environment.
# ---------------------------------------------------------------------------

variable "dev_bucket_name" {
  description = <<-EOT
    Bucket for wip-* / PR-fork artifacts. Object expiry only, no
    versioning, no object-lock.
  EOT
  type        = string
  default     = "ceph-artifacts-dev"
}

variable "dev_expiration_days" {
  description = "Days until objects in the dev bucket expire."
  type        = number
  default     = 30

  validation {
    condition     = var.dev_expiration_days > 0 && var.dev_expiration_days <= 365
    error_message = "dev_expiration_days must be in (0, 365]."
  }
}

variable "branch_bucket_name" {
  description = <<-EOT
    Bucket for main + release-branch builds. Versioning is enabled so
    that the `keep latest N per (branch, distro, arch)` rule can be
    enforced by the publish-repo task (S3 lifecycle has no keep-N
    primitive — see README). A hard time ceiling is enforced via
    lifecycle expiration.
  EOT
  type        = string
  default     = "ceph-artifacts-branch"
}

variable "branch_expiration_days" {
  description = "Hard ceiling on object age in the branch bucket."
  type        = number
  default     = 180

  validation {
    condition     = var.branch_expiration_days > 0 && var.branch_expiration_days <= 730
    error_message = "branch_expiration_days must be in (0, 730]."
  }
}

variable "branch_noncurrent_version_expiration_days" {
  description = <<-EOT
    Days after which noncurrent (superseded) object versions in the
    branch bucket are deleted. Acts as the cleanup tail for the keep-N
    pruner: once the publish-repo task deletes an older version, this
    rule reaps the noncurrent marker.
  EOT
  type        = number
  default     = 7
}

variable "release_bucket_name" {
  description = <<-EOT
    Bucket for tag-driven release artifacts. Object-lock enabled in
    governance mode with a multi-year default retention.
  EOT
  type        = string
  default     = "ceph-artifacts-release"
}

variable "release_object_lock_mode" {
  description = <<-EOT
    Object-lock retention mode for the release bucket. GOVERNANCE
    permits privileged override (the bypass permission is held by an
    audited break-glass role); COMPLIANCE permits no override at all,
    not even by the bucket owner.
  EOT
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.release_object_lock_mode)
    error_message = "release_object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "grype_db_bucket_name" {
  description = <<-EOT
    Bucket for the self-hosted Grype vulnerability database tarballs
    (see ceph-tekton issue #56). The producer Pipeline publishes
    one dated snapshot per build under
    `grype-db/<schema-version>/<date>/vulnerability.db.tar.zst`
    plus a `latest.json` pointer at
    `grype-db/<schema-version>/latest.json`.

    Distinct from the build-artifact buckets:
      - No versioning (each dated path is a fresh object).
      - No object-lock (DB snapshots are tooling, not release
        artifacts).
      - Short keep-N retention via lifecycle expiry.
      - Public read so the vuln-scan Task can fetch the DB via curl
        without authentication, same way clients fetch packages from
        the branch bucket.
  EOT
  type        = string
  default     = "ceph-grype-db"
}

variable "grype_db_expiration_days" {
  description = <<-EOT
    Days until grype-db snapshots in the grype-db bucket expire.
    Approximates "keep last N daily builds" on a daily producer
    cadence: 30 days ≈ last 30 dailies. The `latest.json` pointer is
    excluded from expiry implicitly because the producer rewrites it
    each run (S3 lifecycle compares against last-modified, not
    last-PUT-by-this-producer).
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.grype_db_expiration_days > 0 && var.grype_db_expiration_days <= 365
    error_message = "grype_db_expiration_days must be in (0, 365]."
  }
}

variable "release_object_lock_years" {
  description = <<-EOT
    Default retention period applied to every object PUT into the
    release bucket, in years. 7 mirrors the SOX/HIPAA-style horizon
    typical for signed release artifacts.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.release_object_lock_years > 0 && var.release_object_lock_years <= 100
    error_message = "release_object_lock_years must be in (0, 100]."
  }
}

# ---------------------------------------------------------------------------
# Common inputs
# ---------------------------------------------------------------------------

variable "force_destroy" {
  description = <<-EOT
    Allow `terraform destroy` to delete buckets that still contain
    objects. Safe to enable in the local-dev env (zgw-posix is
    ephemeral). MUST be false in any environment with real
    artifacts — and is *ignored by S3* for the release bucket when
    object-lock retention is still active.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every bucket the module creates."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Backend-flavor toggles
#
# Different S3-compatible backends (zgw-posix, older RGW, current RGW
# Squid+, AWS S3) implement different subsets of the S3 sub-API surface
# the AWS provider always tries to call. These flags let us skip the
# unsupported configuration without forking the module.
# ---------------------------------------------------------------------------

variable "enable_bucket_ownership_controls" {
  description = <<-EOT
    Apply `aws_s3_bucket_ownership_controls`. AWS S3 requires this for
    sane ACL behavior; zgw-posix and older RGW return NotImplemented
    for the PutBucketOwnershipControls call. Default off (dev-safe);
    set true for AWS S3 and recent (Squid+) RGW.
  EOT
  type        = bool
  default     = false
}

variable "enable_public_access_block" {
  description = <<-EOT
    Apply `aws_s3_bucket_public_access_block`. AWS-only sub-API on
    older S3 implementations; zgw-posix and pre-Squid RGW return
    NotImplemented. Default off; set true for AWS S3 and recent RGW.

    When set true AND a bucket has `*_public_read = true`, the
    public-access-block for that bucket is configured *permissively*
    (block_public_policy=false, restrict_public_buckets=false) so the
    public bucket policy can take effect — ACLs remain blocked.
  EOT
  type        = bool
  default     = false
}

variable "enable_versioning" {
  description = <<-EOT
    Manage `aws_s3_bucket_versioning` on the branch and release
    buckets, AND the matching `aws_s3_bucket_object_lock_configuration`
    on release (object-lock requires versioning). Default true.

    Set to false on environments whose S3 backend can't service
    `PutBucketVersioning` — currently the `dev` env when it's pointed
    at `quay.io/dparkes/zgw-posix:latest`, whose `PutBucketVersioning`
    crashes the gateway rather than returning NotImplemented.

    When this flag is false the buckets are still created, but the
    branch bucket loses its keep-N-via-versioning story and the
    release bucket loses object-lock entirely. Dev environments
    accepting this tradeoff get to exercise bucket create + object
    PUT/GET + public-read policy locally; for higher-fidelity
    versioning / object-lock validation, use the `dev-rgw` env
    against a real Ceph RGW (e.g. vstart on a build host).
  EOT
  type        = bool
  default     = true
}

variable "enable_lifecycle" {
  description = <<-EOT
    Manage `aws_s3_bucket_lifecycle_configuration` on the dev / branch /
    release buckets. Default true.

    Set to false on environments where the AWS provider's post-PUT
    consistency wait can't converge — currently the `dev-rgw` env, due
    to an RGW lifecycle GET handler bug that downgrades the V2
    `<Filter></Filter>` shape (which the AWS provider PUTs) to legacy
    V1 `<Prefix></Prefix>` on GET. The provider does a structural diff
    between PUT and GET until they match, times out at 3m, and tears
    the resource out of state. See
    `notes/rgw-lifecycle-empty-filter-v1-downgrade.md` for the
    reproducer and tracking.

    When this flag is false the buckets are still created — only the
    expiry / noncurrent-version-cleanup / mpu-abort rules are skipped.
    The publish-repo keep-N pruner still works (it's a Tekton task,
    not a bucket-side rule).

    Tracked by ceph-tekton issue #57.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Public-mirror semantics
#
# Ceph artifact buckets need anonymous public read so that `apt-get`,
# `dnf`, `podman pull`, and `curl` work against the canonical URLs (this
# is what `download.ceph.com` / `chacra.ceph.com` do today). The module
# expresses this via a per-bucket flag + an optional prefix scope.
#
# The implementation uses a bucket policy granting s3:GetObject to
# Principal "*" — *not* object ACLs. Object ACLs are blocked everywhere
# the operator has enabled public-access-block.
# ---------------------------------------------------------------------------

variable "dev_public_read" {
  description = "Allow anonymous GetObject on the dev bucket (mirror semantics)."
  type        = bool
  default     = false
}

variable "branch_public_read" {
  description = "Allow anonymous GetObject on the branch bucket (mirror semantics)."
  type        = bool
  default     = false
}

variable "release_public_read" {
  description = "Allow anonymous GetObject on the release bucket (mirror semantics)."
  type        = bool
  default     = false
}

variable "grype_db_public_read" {
  description = <<-EOT
    Allow anonymous GetObject on the grype-db bucket. Default true:
    vuln-scan Tasks running in clusters that can't authenticate to
    this RGW account still need to fetch the DB tarball, and the DB
    itself is supply-chain *tooling* (signed via cosign), not
    sensitive content. anchore.io's published DB has the same
    posture.
  EOT
  type        = bool
  default     = true
}

variable "public_read_prefixes" {
  description = <<-EOT
    Object key prefixes (S3-style globs, *not* regex) granted anonymous
    read when a bucket has `*_public_read = true`. Default `["*"]` exposes
    the entire bucket — which is the right call for a yum/apt mirror that
    pulls repodata, packages, and signing-key downloads all under the
    same root.

    To keep an internal `staging/` prefix private during a build, set
    explicit prefixes like `["repodata/*", "packages/*", "dists/*"]`.
  EOT
  type        = list(string)
  default     = ["*"]

  validation {
    condition     = length(var.public_read_prefixes) > 0
    error_message = "public_read_prefixes must contain at least one entry."
  }
}

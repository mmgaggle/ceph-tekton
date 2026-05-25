# ---------------------------------------------------------------------------
# Per-bucket inputs
#
# The module creates exactly the three buckets ceph-tekton needs (dev /
# branch / release). Bucket *names* are inputs so the same module can be
# pointed at MinIO (dev), AWS S3 (parity testing), or RGW (Sepia) with
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
    objects. Safe to enable in dev (MinIO is ephemeral). MUST be false
    in any environment with real artifacts — and is *ignored by S3*
    for the release bucket when object-lock retention is still active.
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
# MinIO and (older) RGW implementations are missing some S3 sub-APIs that
# the AWS provider always tries to call. These flags let us skip the
# unsupported configuration without forking the module.
# ---------------------------------------------------------------------------

variable "enable_bucket_ownership_controls" {
  description = <<-EOT
    Apply `aws_s3_bucket_ownership_controls`. AWS S3 requires this for
    sane ACL behavior; MinIO returns NotImplemented for the
    PutBucketOwnershipControls call. Default off (MinIO-safe); set true
    for AWS and recent RGW.
  EOT
  type        = bool
  default     = false
}

variable "enable_public_access_block" {
  description = <<-EOT
    Apply `aws_s3_bucket_public_access_block`. AWS-only feature; MinIO
    and most RGW versions return NotImplemented. Default off; set true
    for AWS.
  EOT
  type        = bool
  default     = false
}

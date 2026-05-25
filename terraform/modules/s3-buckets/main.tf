# ===========================================================================
# ceph-artifacts-dev
#   wip-* / PR-fork artifacts. Pure expiry. No versioning, no object-lock.
# ===========================================================================

resource "aws_s3_bucket" "dev" {
  bucket        = var.dev_bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_lifecycle_configuration" "dev" {
  bucket = aws_s3_bucket.dev.id

  rule {
    id     = "expire-all-objects"
    status = "Enabled"

    # Empty filter block = applies to every object. The AWS provider
    # 5.x requires the `filter` block to be present even when there's
    # no filtering — omitting it produces a "missing required argument"
    # error, but a block with no contents is the documented "all
    # objects" idiom.
    filter {}

    expiration {
      days = var.dev_expiration_days
    }

    # Reap multipart-upload garbage; cheap insurance.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ===========================================================================
# ceph-artifacts-branch
#   main + release-branch builds. Versioning enabled to support the
#   keep-latest-N pruner that publish-repo runs (see README §"keep-N").
#   Hard time ceiling enforced via lifecycle expiration.
# ===========================================================================

resource "aws_s3_bucket" "branch" {
  bucket        = var.branch_bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "branch" {
  bucket = aws_s3_bucket.branch.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "branch" {
  bucket = aws_s3_bucket.branch.id

  # Time ceiling for current versions.
  rule {
    id     = "expire-current-versions"
    status = "Enabled"

    filter {}

    expiration {
      days = var.branch_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # Reap noncurrent versions left behind by the publish-repo keep-N
  # pruner (and by delete markers under versioning).
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.branch_noncurrent_version_expiration_days
    }
  }

  # Versioning must be on before lifecycle can reference noncurrent
  # versions; depend on it explicitly so first-apply ordering is right.
  depends_on = [aws_s3_bucket_versioning.branch]
}

# ===========================================================================
# ceph-artifacts-release
#   Tag-driven artifacts. Object-lock GOVERNANCE, default ≥ 1y retention.
#
#   S3 protocol constraint: object-lock requires versioning, AND the
#   bucket must be created with object-lock-enabled at creation time.
#   `object_lock_enabled = true` on the bucket resource sets that bit.
# ===========================================================================

resource "aws_s3_bucket" "release" {
  bucket              = var.release_bucket_name
  force_destroy       = var.force_destroy
  object_lock_enabled = true
  tags                = var.tags
}

resource "aws_s3_bucket_versioning" "release" {
  bucket = aws_s3_bucket.release.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "release" {
  bucket = aws_s3_bucket.release.id

  # `object_lock_enabled` here is "Enabled" (string) and is distinct
  # from `aws_s3_bucket.release.object_lock_enabled = true` (bool).
  # The bucket flag is the one-shot opt-in at creation; this attribute
  # says "yes, also apply this configuration". Default in the provider
  # is "Enabled" so it could be omitted — we set it explicitly for
  # clarity.
  object_lock_enabled = "Enabled"

  rule {
    default_retention {
      mode  = var.release_object_lock_mode
      years = var.release_object_lock_years
    }
  }

  depends_on = [aws_s3_bucket_versioning.release]
}

# Optional lifecycle on the release bucket: we deliberately do NOT set
# an expiration that competes with the object-lock retention. Lifecycle
# delete on an object still under retention is silently no-op'd by S3,
# which makes operational reasoning harder. We only sweep aborted
# multipart uploads.
resource "aws_s3_bucket_lifecycle_configuration" "release" {
  bucket = aws_s3_bucket.release.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.release]
}

# ===========================================================================
# AWS-only hardening (toggled off by default for MinIO compatibility)
# ===========================================================================

locals {
  bucket_ids = {
    dev     = aws_s3_bucket.dev.id
    branch  = aws_s3_bucket.branch.id
    release = aws_s3_bucket.release.id
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = var.enable_bucket_ownership_controls ? local.bucket_ids : {}

  bucket = each.value
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.enable_public_access_block ? local.bucket_ids : {}

  bucket = each.value

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

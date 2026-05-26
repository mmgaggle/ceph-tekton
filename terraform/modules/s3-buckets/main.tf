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
  count  = var.enable_lifecycle ? 1 : 0
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
  count  = var.enable_lifecycle ? 1 : 0
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
  count  = var.enable_lifecycle ? 1 : 0
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
# ceph-grype-db
#   Self-hosted Grype vulnerability database snapshots (issue #56).
#   Producer Pipeline publishes one tarball + cosign bundle per build
#   under grype-db/<schema>/<date>/...; vuln-scan Tasks fetch +
#   cosign-verify before scanning. Different content class from the
#   three build-artifact buckets above:
#     - no versioning (each date is a fresh prefix)
#     - no object-lock (DB snapshots are tooling, not releases)
#     - short retention (keep last N dailies via lifecycle expiry)
# ===========================================================================

resource "aws_s3_bucket" "grype_db" {
  bucket        = var.grype_db_bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_lifecycle_configuration" "grype_db" {
  count  = var.enable_lifecycle ? 1 : 0
  bucket = aws_s3_bucket.grype_db.id

  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"

    filter {}

    expiration {
      days = var.grype_db_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ===========================================================================
# AWS-only hardening (toggled off by default for MinIO compatibility)
# ===========================================================================

locals {
  bucket_ids = {
    dev      = aws_s3_bucket.dev.id
    branch   = aws_s3_bucket.branch.id
    release  = aws_s3_bucket.release.id
    grype_db = aws_s3_bucket.grype_db.id
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

  # ACL-style public access is always blocked. Object ACLs are not the
  # mechanism we use for public mirror semantics — that's the public
  # bucket policy (see `aws_s3_bucket_policy.public_read` below).
  block_public_acls  = true
  ignore_public_acls = true

  # Bucket-policy-based public access: blocked by default, permitted
  # for buckets that opted into mirror semantics via `*_public_read`.
  block_public_policy     = !lookup(local.bucket_public_read, each.key, false)
  restrict_public_buckets = !lookup(local.bucket_public_read, each.key, false)
}

# ===========================================================================
# Public-mirror bucket policies
#
# Buckets with `*_public_read = true` get a policy granting anonymous
# s3:GetObject (and s3:GetObjectVersion for versioned buckets) on the
# configured prefixes. This is the read side of the chacra mirror —
# every `dnf install ceph`, `apt-get install ceph-common`, and
# `podman pull quay.io/ceph/ceph` traverses this path.
#
# Writes remain restricted to authenticated principals (via the
# upstream STS roles), and object-lock on the release bucket is
# orthogonal: it controls whether objects can be deleted/overwritten,
# not whether they can be read.
# ===========================================================================

locals {
  bucket_public_read = {
    dev      = var.dev_public_read
    branch   = var.branch_public_read
    release  = var.release_public_read
    grype_db = var.grype_db_public_read
  }
  buckets_with_public_read = {
    for k, v in local.bucket_public_read : k => local.bucket_ids[k] if v
  }
}

data "aws_iam_policy_document" "public_read" {
  for_each = local.buckets_with_public_read

  statement {
    sid     = "AllowAnonymousReadOnPrefixes"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    # public_read_prefixes uses S3-style globs (e.g. "repodata/*"). The
    # default "*" yields the full bucket. ARN format is the same on
    # AWS, RGW, and MinIO — bucket-policy ARN strings are not validated
    # against a backend-specific partition.
    resources = [
      for prefix in var.public_read_prefixes :
      "arn:aws:s3:::${each.value}/${prefix}"
    ]
  }
}

resource "aws_s3_bucket_policy" "public_read" {
  for_each = local.buckets_with_public_read

  bucket = each.value
  policy = data.aws_iam_policy_document.public_read[each.key].json

  # public-access-block must be configured (permissively) BEFORE the
  # public policy is applied, otherwise AWS rejects the policy as a
  # would-be public statement against a blocked bucket. depends_on is
  # safe even when the public-access-block resource has 0 instances
  # (e.g. against MinIO with enable_public_access_block = false).
  depends_on = [
    aws_s3_bucket_ownership_controls.this,
    aws_s3_bucket_public_access_block.this,
  ]
}

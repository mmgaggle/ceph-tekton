output "dev_bucket" {
  description = "Name of the dev (wip-*/PR-fork) artifacts bucket."
  value       = aws_s3_bucket.dev.id
}

output "branch_bucket" {
  description = "Name of the branch (main + release-branch) artifacts bucket."
  value       = aws_s3_bucket.branch.id
}

output "release_bucket" {
  description = "Name of the release (tag-driven) artifacts bucket."
  value       = aws_s3_bucket.release.id
}

output "buckets" {
  description = "All three bucket names keyed by lifecycle class."
  value = {
    dev     = aws_s3_bucket.dev.id
    branch  = aws_s3_bucket.branch.id
    release = aws_s3_bucket.release.id
  }
}

output "release_object_lock" {
  description = "Effective object-lock policy on the release bucket."
  value = {
    mode  = var.release_object_lock_mode
    years = var.release_object_lock_years
  }
}

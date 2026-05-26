output "buckets" {
  description = "Bucket names created on the local RGW."
  value       = module.artifacts.buckets
}

output "release_object_lock" {
  description = <<-EOT
    Effective object-lock policy on the release bucket. Always
    "disabled" in the dev env, since zgw-posix's PutBucketVersioning
    crashes the gateway and object-lock requires versioning. See
    `terraform/environments/dev-rgw/` for a backend that actually
    exercises object-lock retention against real Ceph RGW.
  EOT
  value       = module.artifacts.release_object_lock
}

output "endpoint" {
  description = "Local RGW endpoint the buckets live on."
  value       = var.rgw_endpoint
}

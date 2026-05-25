output "buckets" {
  description = "Bucket names created on Sepia RGW."
  value       = module.artifacts.buckets
}

output "release_object_lock" {
  description = "Effective object-lock policy on the release bucket."
  value       = module.artifacts.release_object_lock
}

output "endpoint" {
  description = "Sepia RGW endpoint the buckets live on."
  value       = var.rgw_endpoint
}

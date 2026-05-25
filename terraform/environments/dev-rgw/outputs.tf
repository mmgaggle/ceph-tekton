output "buckets" {
  description = "Bucket names created on the test RGW."
  value       = module.artifacts.buckets
}

output "release_object_lock" {
  description = "Effective object-lock policy on the release bucket."
  value       = module.artifacts.release_object_lock
}

output "public_read" {
  description = "Per-bucket public-read flag and the prefix scope applied."
  value       = module.artifacts.public_read
}

output "endpoint" {
  description = "RGW endpoint the buckets live on."
  value       = var.rgw_endpoint
}

output "bucket_prefix" {
  description = "Namespace prefix used for this dev-rgw apply."
  value       = var.bucket_prefix
}

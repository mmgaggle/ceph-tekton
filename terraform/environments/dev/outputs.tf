output "buckets" {
  description = "Bucket names created in MinIO."
  value       = module.artifacts.buckets
}

output "release_object_lock" {
  description = "Effective object-lock policy on the release bucket."
  value       = module.artifacts.release_object_lock
}

output "endpoint" {
  description = "MinIO endpoint the buckets live on."
  value       = var.minio_endpoint
}

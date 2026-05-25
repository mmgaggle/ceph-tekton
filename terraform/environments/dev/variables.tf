variable "minio_endpoint" {
  description = "URL of the MinIO server, e.g. http://127.0.0.1:9000"
  type        = string
  default     = "http://127.0.0.1:9000"
}

variable "minio_access_key" {
  description = "MinIO root / admin access key."
  type        = string
  default     = "minioadmin"
}

variable "minio_secret_key" {
  description = "MinIO root / admin secret key."
  type        = string
  default     = "minioadmin"
  sensitive   = true
}

variable "minio_region" {
  description = <<-EOT
    Region string MinIO is configured with. MinIO defaults to
    `us-east-1` and requires the client to assert the same value.
  EOT
  type        = string
  default     = "us-east-1"
}

variable "bucket_prefix" {
  description = <<-EOT
    Optional prefix on bucket names so multiple devs can share a
    MinIO instance. Empty string = plain `ceph-artifacts-*` names
    matching Sepia.
  EOT
  type        = string
  default     = ""
}

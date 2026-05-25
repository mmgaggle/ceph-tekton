variable "rgw_endpoint" {
  description = <<-EOT
    Test-cluster RGW S3 endpoint URL, e.g. https://s3.test.ceph.example.com.
    Leave at the placeholder default until you have credentials. The
    apply runbook is in README.md.
  EOT
  type        = string
  default     = "https://s3.PLACEHOLDER.example.com"
}

variable "rgw_region" {
  description = "Region name configured on the test RGW (often 'default' for non-multisite)."
  type        = string
  default     = "default"
}

variable "rgw_access_key" {
  description = <<-EOT
    Test-user RGW access key. Source from env (`TF_VAR_rgw_access_key`)
    or a per-dev credential issued by the RGW admin; do NOT commit a
    value here. This is bootstrap-grade — a long-lived key for the
    test user. Production Sepia gets STS via OIDC (#7); dev-rgw uses
    static creds to keep the bootstrap shallow.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "rgw_secret_key" {
  description = "Test-user RGW secret key. See rgw_access_key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "bucket_prefix" {
  description = <<-EOT
    Namespace prefix prepended to every bucket name. Lets multiple
    developers share the same RGW without bucket-name collisions.
    Use your username, or `team-<feature>` for a shared sandbox.

    Example: `kyle-` produces `kyle-ceph-artifacts-dev`, etc.
  EOT
  type        = string
  default     = "devtest-"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.bucket_prefix))
    error_message = "bucket_prefix must be DNS-safe (lowercase, digits, hyphen)."
  }
}

variable "release_object_lock_years" {
  description = <<-EOT
    Object-lock retention on the release bucket, in years. dev-rgw
    keeps this at 1 (the minimum that exercises the API) so test
    artifacts age out cheaply — `force_destroy = true` plus a
    governance-bypass cleanup still respects the lock until manually
    overridden.
  EOT
  type        = number
  default     = 1
}

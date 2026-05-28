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

variable "credentials_path" {
  description = <<-EOT
    Path to an AWS-format credentials file (the same format the
    `aws` CLI reads from `~/.aws/credentials`). Tilde-expanded by
    `pathexpand()` in main.tf.

    Bootstrap a profile section for your test RGW:

      [my-test-rgw]
      aws_access_key_id = ...
      aws_secret_access_key = ...

    Then set `credentials_profile = "my-test-rgw"` here (or scope
    via `TF_VAR_credentials_profile`). Production Sepia will get
    STS via OIDC (#7); dev-rgw uses long-lived test-user keys to
    keep the bootstrap shallow — same posture as before, just
    sourced via the standard AWS credentials chain instead of
    `TF_VAR_rgw_*` env vars.
  EOT
  type        = string
  default     = "~/.aws/credentials"
}

variable "credentials_profile" {
  description = <<-EOT
    Named profile inside `credentials_path` to authenticate against.
    Per-cluster profiles (e.g. `kyle-rgw-test`, `team-rgw-shared`)
    let devs juggle multiple Ceph endpoints without juggling env
    vars.
  EOT
  type        = string
  default     = "default"
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

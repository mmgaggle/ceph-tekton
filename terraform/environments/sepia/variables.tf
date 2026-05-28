variable "rgw_endpoint" {
  description = <<-EOT
    Sepia RGW S3 endpoint URL, e.g. https://s3.ceph.example.com.
    Leave at the placeholder default — this stub is documented but
    not applied. Replace before any real `terraform apply`.
  EOT
  type        = string
  default     = "https://s3.PLACEHOLDER.example.com"
}

variable "rgw_region" {
  description = "Region name configured on Sepia RGW."
  type        = string
  default     = "default"
}

variable "credentials_path" {
  description = <<-EOT
    Path to an AWS-format credentials file (the same format the
    `aws` CLI reads from `~/.aws/credentials`). Tilde-expanded by
    `pathexpand()` in main.tf.

    Bootstrap a profile section with the admin-issued one-time
    credential:

      [sepia-bootstrap]
      aws_access_key_id = ...
      aws_secret_access_key = ...

    Then set `credentials_profile = "sepia-bootstrap"` here. Once
    the RGW OIDC trust + role from issue #7 lands, the long-lived
    bootstrap profile goes away and this provider switches to
    `AssumeRoleWithWebIdentity` from a CI SA token.
  EOT
  type        = string
  default     = "~/.aws/credentials"
}

variable "credentials_profile" {
  description = <<-EOT
    Named profile inside `credentials_path` to authenticate against.
    Sepia bootstrap-grade — the profile maps to the admin-issued
    one-time credential while #7's OIDC trust isn't yet wired.
  EOT
  type        = string
  default     = "default"
}

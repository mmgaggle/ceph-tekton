variable "rgw_endpoint" {
  description = <<-EOT
    URL of the local RGW (`quay.io/dparkes/zgw-posix:latest` by
    default — see `hack/verify-s3-module.sh`). The default port
    matches the verify script's container publish.
  EOT
  type        = string
  default     = "http://127.0.0.1:8000"
}

variable "credentials_path" {
  description = <<-EOT
    Path to an AWS-format credentials file (the same format the
    `aws` CLI reads from `~/.aws/credentials`). Tilde-expanded by
    `pathexpand()` in main.tf so `~/.aws/credentials` Just Works.

    For zgw-posix dev: bootstrap the file once with cephtekton
    creds for the local profile:

      mkdir -p ~/.aws
      cat >> ~/.aws/credentials <<'EOF'
      [zgw-posix]
      aws_access_key_id = cephtekton
      aws_secret_access_key = cephtekton
      EOF

    Then either set `credentials_profile = "zgw-posix"` here or
    use the file's `[default]` profile.
  EOT
  type        = string
  default     = "~/.aws/credentials"
}

variable "credentials_profile" {
  description = <<-EOT
    Named profile inside `credentials_path` to authenticate against.
    Default `default` matches the AWS-CLI's own default; override to
    `zgw-posix` (or whatever you named the local profile) if you
    don't want to dedicate the `[default]` section to the dev RGW.
  EOT
  type        = string
  default     = "default"
}

variable "rgw_region" {
  description = <<-EOT
    Region string the local RGW is configured with. RGW's default
    zone-group name is `default`; that's what `radosgw-admin` writes
    and what zgw-posix returns in its `LocationConstraint`.
  EOT
  type        = string
  default     = "default"
}

variable "bucket_prefix" {
  description = <<-EOT
    Optional prefix on bucket names so multiple devs can share a
    single zgw-posix instance. Empty string = plain `ceph-artifacts-*`
    names matching Sepia.
  EOT
  type        = string
  default     = ""
}

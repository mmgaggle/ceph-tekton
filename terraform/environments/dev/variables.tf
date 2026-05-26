variable "rgw_endpoint" {
  description = <<-EOT
    URL of the local RGW (`quay.io/dparkes/zgw-posix:latest` by
    default — see `hack/verify-s3-module.sh`). The default port
    matches the verify script's container publish.
  EOT
  type        = string
  default     = "http://127.0.0.1:8000"
}

variable "rgw_access_key" {
  description = <<-EOT
    Local RGW access key. zgw-posix accepts an arbitrary key
    pair when started in dev mode; the verify script uses
    `cephtekton` for both fields.
  EOT
  type        = string
  default     = "cephtekton"
}

variable "rgw_secret_key" {
  description = "Local RGW secret key. See `rgw_access_key`."
  type        = string
  default     = "cephtekton"
  sensitive   = true
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

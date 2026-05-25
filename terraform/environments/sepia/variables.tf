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

variable "rgw_access_key" {
  description = <<-EOT
    Bootstrap RGW access key. Source from env (`TF_VAR_rgw_access_key`)
    or a one-time credential issued by the RGW admin; do NOT commit a
    value here. Once the RGW OIDC trust + role from issue #2 lands,
    this gets replaced with `AssumeRoleWithWebIdentity` from a CI SA
    token and these long-lived keys go away.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "rgw_secret_key" {
  description = "Bootstrap RGW secret key. See rgw_access_key."
  type        = string
  default     = ""
  sensitive   = true
}

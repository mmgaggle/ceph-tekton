terraform {
  # 1.5+ is enough here — the dev-rgw env keeps state in a local file
  # (not an S3 backend that would need the endpoints map). The sepia
  # env requires 1.6+ for its S3 backend stanza.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30.0, < 6.0.0"
    }
  }

  # State backend
  # -------------
  # Local state is fine for dev-rgw: this is per-developer test scope,
  # the `bucket_prefix` variable scopes resources so multiple devs can
  # share the same RGW without collisions, and `force_destroy = true`
  # means a stale state file is recoverable by re-applying.
  #
  # If you want to share dev-rgw state with a teammate, point at the
  # same `ceph-tekton-tfstate` bucket the sepia env uses, with a
  # different key:
  #
  #   backend "s3" {
  #     bucket    = "ceph-tekton-tfstate"
  #     key       = "environments/dev-rgw/${var.bucket_prefix}.tfstate"
  #     endpoints = { s3 = var.rgw_endpoint }
  #     ...
  #   }
}

terraform {
  # 1.6+: S3 backend supports the `endpoints = { s3 = ... }` map
  # form needed to point at RGW.
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30.0, < 6.0.0"
    }
  }

  # State backend documentation
  # ---------------------------
  # Sepia env state lives in a dedicated bucket on Sepia RGW itself:
  #
  #   bucket   = "ceph-tekton-tfstate"
  #   key      = "environments/sepia/s3-buckets.tfstate"
  #   region   = "us-east-1"
  #   endpoint = "https://s3.ceph.example.com"   # Sepia RGW
  #
  # The `ceph-tekton-tfstate` bucket itself is bootstrapped
  # out-of-band (chicken-and-egg): a one-time `aws s3api create-bucket`
  # against the RGW endpoint, with versioning enabled so we have a
  # state recovery path. Object-lock is NOT enabled on the tfstate
  # bucket — terraform's atomic write semantics rely on overwriting
  # the current version.
  #
  # The backend block below is intentionally COMMENTED OUT so that
  # `terraform init` in this stub directory succeeds (with a local
  # state file) for read-only operations like `terraform validate`
  # and `terraform fmt`. Uncomment, fill in the endpoint, and run
  # `terraform init -migrate-state` when wiring up the real Sepia
  # environment.
  #
  # backend "s3" {
  #   bucket                      = "ceph-tekton-tfstate"
  #   key                         = "environments/sepia/s3-buckets.tfstate"
  #   region                      = "us-east-1"
  #   endpoints                   = { s3 = "https://s3.ceph.example.com" }
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_requesting_account_id  = true
  #   skip_region_validation      = true
  #   use_path_style              = true
  #   # DynamoDB locking is not available on RGW; rely on the team's
  #   # change-control SOP (one operator at a time) and on the
  #   # `force_unlock` escape hatch if a run is interrupted.
  # }
}

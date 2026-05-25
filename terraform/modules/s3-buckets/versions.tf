terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 5.30+ has stable `aws_s3_bucket_lifecycle_configuration`,
      # `aws_s3_bucket_versioning`, and `aws_s3_bucket_object_lock_configuration`
      # as separate resources. Pin to 5.x for now — 6.x added a
      # `transition_default_minimum_object_size` argument to the
      # lifecycle resource that we haven't validated here.
      version = ">= 5.30.0, < 6.0.0"
    }
  }
}

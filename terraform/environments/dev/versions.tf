terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30.0, < 6.0.0"
    }
  }

  # Dev env keeps state local so a developer can blow away their
  # whole working tree and start over. Sepia uses an S3 backend.
  backend "local" {
    path = "terraform.tfstate"
  }
}

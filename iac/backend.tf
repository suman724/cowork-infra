###############################################################################
# Terraform Backend Configuration
#
# S3 backend with DynamoDB state locking. One state file per environment.
# Each environment directory uses a workspace or separate backend config.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80"
    }
  }
}

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Repo      = "swares/HomeLab-aws"
      # "permanent", not "ephemeral": the orphan sweep in docs/RUNBOOK.md
      # filters on Lifecycle=ephemeral, so this module's resources are never
      # mistaken for teardown leftovers.
      Lifecycle = "permanent"
    }
  }
}

terraform {
  required_version = ">= 1.10.0" # use_lockfile on the S3 backend needs 1.10+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
    # PINNED TO 2.x DELIBERATELY. The helm provider changed its configuration
    # syntax in 3.0 (the `kubernetes` block became an attribute, and `set`
    # blocks became a list attribute). Everything in argocd.tf is written for
    # 2.x. Bumping this is a real edit, not a version bump.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # For the IRSA ServiceAccount in litellm.tf. Only v1 resources are used
    # (kubernetes_namespace_v1, kubernetes_service_account_v1), which validate
    # at apply time. NOT kubernetes_manifest - that one needs a live cluster
    # at plan time, which an ephemeral cluster never has.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.36, < 3.0"
    }
    # For the LiteLLM master key (litellm.tf): a random value per cluster.
    # No AWS resource, nothing for the teardown policy to cover.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Repo      = "swares/HomeLab-aws"
      Lifecycle = "ephemeral"
    }
  }
}

# The helm and kubernetes providers authenticate with a short-lived token
# minted by the AWS CLI at apply time. This is why the teardown host needs a working `aws`
# binary and not just tofu - see docs/RUNBOOK.md.
provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
    }
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region]
  }
}

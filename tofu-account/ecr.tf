# ---------------------------------------------------------------------------
# Phase 2b: where the m5stack-adapter image lives.
#
# PERMANENT, in tofu-account/, not tofu/: the image is built once from
# swares/My_M5Stack_Core_Framework and pulled by every nightly cluster. In
# tofu/ it would be destroyed at 02:00 and need rebuilding every session.
#
# Private, not ECR Public: the repository address contains the account ID, so
# it never appears in git - tofu/ builds it from aws_caller_identity and hands
# it to the Argo Application as an image-name override (tofu/argocd.tf).
#
# Nodes pull with their existing AmazonEC2ContainerRegistryReadOnly policy
# (tofu/iam.tf). lab-teardown needs nothing: it never touches this module.
#
# Cost: storage at $0.10/GB-month, about a cent for a few ~100 MB images.
# The lifecycle policy keeps it that way.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "adapter" {
  name = var.adapter_repository

  # A tag names one image forever. The Deployment pins a tag, so a pushed
  # image can never change underneath a running cluster.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Refuse to delete a repository that still holds images. Emptying it is a
  # deliberate act, not a side effect of a refactor.
  force_delete = false
}

resource "aws_ecr_lifecycle_policy" "adapter" {
  repository = aws_ecr_repository.adapter.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images (failed or superseded pushes) after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 3 most recent images; enough to roll back twice"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 3
        }
        action = { type = "expire" }
      },
    ]
  })
}

output "adapter_repository_url" {
  description = "Push target for `make adapter-push`. Contains the account ID: console only, never git."
  value       = aws_ecr_repository.adapter.repository_url
}

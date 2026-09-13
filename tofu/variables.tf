variable "region" {
  description = "AWS region. Pinned to us-west-2 for g4dn depth (phase 3) and Bedrock model availability."
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "lab-sandbox"
}

variable "cluster_version" {
  description = <<-EOT
    Kubernetes minor version. Keep this INSIDE standard support. Once a version
    falls into extended support the control plane goes from $0.10/hr to $0.60/hr
    - $438/mo instead of $73/mo for a cluster you forgot about. Check the EKS
    version calendar before pinning.
  EOT
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = <<-EOT
    VPC CIDR. MUST NOT overlap the lab's 192.168.1.0/24 - if Seam A (Hybrid
    Nodes) ever happens, an overlap makes the whole thing unroutable and the
    fix is rebuilding the VPC. 10.42.0.0/16 is deliberately far away.
  EOT
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Availability zones. Two is the EKS minimum for the control plane ENIs."
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b"]
}

variable "node_instance_types" {
  description = <<-EOT
    Multiple types on purpose: a spot nodegroup with one instance type is the
    single most common cause of 'no capacity' at 7am. More types, more pools.
  EOT
  type        = list(string)
  default     = ["t3.medium", "t3a.medium", "t3.large", "t3a.large"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "gitops_repo_url" {
  description = <<-EOT
    HTTPS, not SSH. The repo is public, so Argo reads it anonymously and there
    is no deploy key, no credential secret, and nothing shared with the lab.
    That is deliberate - it is what keeps this cluster detachable.
  EOT
  type        = string
  default     = "https://github.com/swares/HomeLab-aws.git"
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (chart version, not appVersion). Pinned - Kyverno's disallow-latest-tag would reject an unpinned image anyway."
  type        = string
  default     = "7.7.11"
}

variable "budget_limit_usd" {
  description = "Monthly budget. Alarms are the backstop for the forgotten-cluster failure mode; the nightly teardown timer is the primary control."
  type        = string
  default     = "40"
}

variable "budget_email" {
  description = "Email for budget + teardown alarms. Set in terraform.tfvars."
  type        = string
}

variable "extra_admin_principal_arns" {
  description = <<-EOT
    Extra IAM principals granted cluster-admin via EKS access entries. The
    identity that runs `tofu apply` already gets admin via
    bootstrap_cluster_creator_admin_permissions. Add the n150-2 teardown
    identity here if it differs from your interactive one.
  EOT
  type        = list(string)
  default     = []
}

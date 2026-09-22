variable "region" {
  description = <<-EOT
    AWS region. us-east-1 has the broadest Bedrock model availability (phase 1)
    and the deepest g4dn spot capacity (phase 3), which is why it is a good fit
    here.

    Trade-off worth knowing: it is also AWS's oldest and busiest region and
    historically the most outage-prone, and it hosts the global control planes
    for IAM, CloudFront and Route 53. For an ephemeral training sandbox that
    does not matter. Do not infer from this choice that it is the right default
    for anything that needs to stay up.
  EOT
  type        = string
  default     = "us-east-1"
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
    version calendar before pinning:
      aws eks describe-cluster-versions --region us-east-1 \
        --query 'clusterVersions[].[clusterVersion,versionStatus]' --output table

    1.35 (standard support until 2027-03-27) rather than 1.36, deliberately:
    the CEILING IS KYVERNO, NOT EKS. Kyverno's published compatibility matrix
    tops out at Kubernetes 1.35 as of 2026-09-21. Before bumping this, confirm
    the pinned Kyverno release lists the new version.

    History: this defaulted to 1.33 until 2026-09-21. 1.33 left standard
    support on 2026-07-29, so the first apply would have billed the extended
    rate from minute one. Caught before any cluster was created.
  EOT
  type        = string
  default     = "1.35"
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
  description = <<-EOT
    Availability zones. Two is the EKS minimum for the control plane ENIs.

    TWO us-east-1 SPECIFICS:

    1. AZ NAMES ARE RANDOMISED PER ACCOUNT. Your us-east-1a is not the same
       physical AZ as anyone else's. Names map to stable AZ IDs (use1-az1 etc.)
       which differ per account - check with:
         aws ec2 describe-availability-zones --region us-east-1 \
           --query 'AvailabilityZones[].[ZoneName,ZoneId]' --output table

    2. us-east-1e IS THE ONE TO AVOID. It is the oldest hardware in the region
       and does not offer several newer instance families, including some t3a
       and g-series types. If you widen this list, skip 1e or expect a
       confusing InvalidParameterValue at nodegroup creation.

    1a and 1b are safe defaults. An alternative is to drop this variable and
    select AZs dynamically with an aws_availability_zones data source filtered
    on instance-type offerings - more robust, but more moving parts than a
    sandbox needs.
  EOT
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
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
  description = <<-EOT
    argo-cd Helm chart version (chart version, not appVersion). Pinned -
    Kyverno's disallow-latest-tag would reject an unpinned image anyway.

    10.9.2 ships Argo CD v3.5.3. Crossed three chart majors from 7.7.11:
      8.0  Argo CD 3.0
      9.0  configs.params removed from values.yaml (still overridable; unused here)
      10.0 global.networkPolicy.create defaults to true. No effect on EKS
           unless the VPC CNI network-policy agent is enabled, and
           port-forward is unaffected either way.
  EOT
  type        = string
  default     = "10.9.2"
}

variable "argocd_apps_chart_version" {
  description = <<-EOT
    argocd-apps Helm chart version. This chart only renders Application and
    AppProject objects - here, the app-of-apps root. See tofu/argocd.tf for why
    the root cannot live in the argo-cd release itself.
  EOT
  type        = string
  default     = "2.0.5"
}

variable "teardown_user_name" {
  description = "IAM user the nightly teardown runs as. Created by tofu-account/, granted cluster-admin by tofu/eks.tf."
  type        = string
  default     = "lab-teardown"
}

variable "extra_admin_principal_arns" {
  description = <<-EOT
    Extra IAM principals granted cluster-admin via EKS access entries. The
    identity that runs `tofu apply` already gets admin via
    bootstrap_cluster_creator_admin_permissions, and lab-teardown gets it
    from its own access entry in eks.tf. Leave empty unless a third identity
    needs cluster access.
  EOT
  type        = list(string)
  default     = []
}

variable "alb_controller_chart_version" {
  description = <<-EOT
    aws-load-balancer-controller Helm chart version (chart and appVersion move
    together; 3.5.0 = controller v3.5.0). When bumping this, re-vendor the IAM
    policy in tofu/policies/ to the matching tag - a newer controller calling an
    API the old policy does not allow fails at ALB creation time, not at apply.
  EOT
  type        = string
  default     = "3.5.0"
}

variable "alb_allowed_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach the ingress ALB on port 80. Set this in
    terraform.tfvars (gitignored) to your own address - it does NOT belong in
    this public repo. Empty means the SG is created with no ingress rule, so
    the ALB answers nobody, which is the safe default for an unattended apply.
  EOT
  type        = list(string)
  default     = []

  validation {
    # An open webhook on a public ALB is exactly what this phase should not
    # teach. Widen deliberately in a branch if a demo ever needs it.
    condition     = !contains(var.alb_allowed_cidrs, "0.0.0.0/0")
    error_message = "Refusing 0.0.0.0/0: the sandbox ALB is reachable from the internet and its backends have no auth."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "budget_email" {
  description = "Where budget alerts go. Set in terraform.tfvars (gitignored)."
  type        = string
}

variable "budget_limit_usd" {
  description = <<-EOT
    Monthly budget for the WHOLE ACCOUNT - there is no cost filter, on purpose.
    The failure it exists to catch is "something is billing that should not
    be", and that something is not guaranteed to carry this repo's tags.
  EOT
  type        = string
  default     = "40"
}

variable "adapter_repository" {
  description = <<-EOT
    ECR repository for the m5stack-adapter image (phase 2b). MUST match
    var.adapter_repository in tofu/ - that module builds the image address
    from the same name without reading this module's state.
  EOT
  type        = string
  default     = "lab-sandbox/m5stack-adapter"
}

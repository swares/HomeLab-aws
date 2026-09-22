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

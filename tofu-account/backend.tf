# ---------------------------------------------------------------------------
# PERMANENT account-level resources. Deliberately NOT part of tofu/.
#
# tofu/ is destroyed every night. Anything whose job is to notice that the
# nightly destroy did not happen cannot live there: on the first real teardown
# (2026-09-21) the budget was one of the first resources destroyed - so a
# destroy that failed halfway would have left the cluster running and its
# alarm already gone.
#
# Same state bucket as tofu/, different key. `make eks-down` never touches
# this module, and nothing should ever add it there.
# ---------------------------------------------------------------------------
terraform {
  backend "s3" {
    bucket       = "swares-lab-tofu-state"
    key          = "account/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

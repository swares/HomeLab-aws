# ---------------------------------------------------------------------------
# State lives in S3, NOT in the lab's Minio.
#
# Reason, and it is the whole reason: if the lab is down you must still be able
# to run `tofu destroy`. State behind Minio behind the H4 means a lab outage
# turns into an EKS control plane you are paying $0.10/hr for and cannot reach.
#
# `use_lockfile = true` is native S3 conditional-write locking. No DynamoDB
# table is needed (and none should be created - that pattern is obsolete).
#
# BOOTSTRAP: this bucket cannot be created by the module that stores its state
# in it. Create it once, out of band, before the first `tofu init`:
#
#   aws s3api create-bucket --bucket swares-lab-tofu-state \
#     --region us-west-2 \
#     --create-bucket-configuration LocationConstraint=us-west-2
#   aws s3api put-bucket-versioning --bucket swares-lab-tofu-state \
#     --versioning-configuration Status=Enabled
#   aws s3api put-public-access-block --bucket swares-lab-tofu-state \
#     --public-access-block-configuration \
#     "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
#
# Versioning is not optional. It is the only undo for a corrupted state file.
# ---------------------------------------------------------------------------
terraform {
  backend "s3" {
    bucket       = "swares-lab-tofu-state"
    key          = "eks-sandbox/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

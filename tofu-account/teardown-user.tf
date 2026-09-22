# ---------------------------------------------------------------------------
# lab-teardown: the IAM identity the 02:00 timer on n150-2 runs as.
#
# PERMANENT, and therefore here rather than in tofu/: tofu/ cannot create the
# identity that is going to destroy tofu/.
#
# Scope: read everything tofu/ refreshes, delete only what tofu/ creates,
# create NOTHING. Two reasons it is kept this narrow:
#   1. Its access key lives on disk on a lab node.
#   2. The same key is item 8 of docs/BREAK-GLASS.md - on paper, off-site,
#      usable from anywhere with no second factor.
# A stolen copy can stop the sandbox. It cannot build one, touch the budget,
# read the account state, or reach IAM beyond the two sandbox roles.
#
# THE ACCESS KEY IS NOT CREATED HERE, deliberately. An aws_iam_access_key
# resource would write the secret into tofu state in S3. Create it by hand
# (docs/RUNBOOK.md, "Teardown timer") so it only ever exists in
# /etc/eks-sandbox/teardown.env and on the envelope.
#
# Kubernetes access is separate: every `make eks-up` grants this user
# cluster-admin through an EKS access entry (tofu/eks.tf). Without that, the
# helm-release step of `tofu destroy` fails with Unauthorized and the cluster
# stays up - which is the one failure this user exists to prevent.
#
# IF A NIGHTLY TEARDOWN FAILS WITH AccessDenied: a new resource type was added
# to tofu/ without extending this policy. The journal names the missing
# action. Add it here, `make account-apply`, re-run the service by hand.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  cluster    = "lab-sandbox"
  eks_arn    = "arn:aws:eks:${var.region}:${local.account_id}"
}

resource "aws_iam_user" "teardown" {
  name = "lab-teardown"
  path = "/homelab-aws/"
}

data "aws_iam_policy_document" "teardown" {
  # --- OpenTofu state: the sandbox's key only, never account/ -------------
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::swares-lab-tofu-state"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      # "env:/*" is NOT optional. `tofu init` enumerates workspaces with
      # ListObjectsV2 prefix=env:/ (the S3 backend's workspace_key_prefix).
      # Seen in the very first init error on 2026-09-21: "Failed to get
      # existing workspaces ... ListObjectsV2". Without it the timer's init
      # fails AccessDenied before destroy ever starts. It lists key NAMES
      # only; reading any object still needs StateReadWrite below.
      values = ["eks-sandbox/*", "env:/*"]
    }
  }
  statement {
    sid     = "StateReadWrite"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    # terraform.tfstate plus the .tflock that use_lockfile writes beside it.
    resources = ["arn:aws:s3:::swares-lab-tofu-state/eks-sandbox/*"]
  }

  # --- Read: everything `tofu destroy` refreshes first --------------------
  statement {
    sid = "ReadForRefresh"
    actions = [
      "ec2:Describe*",
      "eks:ListClusters",
      "elasticloadbalancing:DescribeLoadBalancers", # teardown script's LB wait
    ]
    resources = ["*"]
  }

  # --- EKS: only the lab-sandbox cluster and what hangs off it ------------
  statement {
    sid = "EksSandboxOnly"
    actions = [
      "eks:Describe*", "eks:List*",
      "eks:DeleteCluster", "eks:DeleteNodegroup", "eks:DeleteAddon",
      "eks:DeleteAccessEntry", "eks:DisassociateAccessPolicy",
    ]
    resources = [
      "${local.eks_arn}:cluster/${local.cluster}",
      "${local.eks_arn}:nodegroup/${local.cluster}/*",
      "${local.eks_arn}:addon/${local.cluster}/*",
      "${local.eks_arn}:access-entry/${local.cluster}/*",
    ]
  }

  # --- EC2: delete only resources tagged as this repo's AND ephemeral -----
  # The Lifecycle condition is what keeps this key away from anything
  # permanent, including anything tofu-account/ might one day own.
  statement {
    sid = "Ec2DeleteEphemeralOnly"
    actions = [
      "ec2:DeleteVpc", "ec2:DeleteSubnet",
      "ec2:DeleteRouteTable", "ec2:DisassociateRouteTable",
      "ec2:DeleteInternetGateway", "ec2:DetachInternetGateway",
      # Phase 2: tofu's own lab-sandbox-alb-ingress SG carries these tags.
      # Deleting a security group means revoking its rules first.
      "ec2:DeleteSecurityGroup",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Repo"
      values   = ["swares/HomeLab-aws"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Lifecycle"
      values   = ["ephemeral"]
    }
  }

  # --- Security groups the AWS Load Balancer Controller leaves behind -----
  # Phase 2. Normally the controller deletes its own SGs when the Ingress
  # goes: eks-teardown.sh removes Ingresses first and waits for the load
  # balancers to disappear. But if the controller is already gone, or an ALB
  # delete raced, its SGs survive - and a VPC cannot be deleted while a
  # security group still lives in it, so the whole teardown stops with
  # DependencyViolation and the cluster stays up, billing.
  #
  # These SGs carry the controller's own tag, NOT this repo's tags, so the
  # Ec2DeleteEphemeralOnly statement above cannot reach them. Scoping on
  # elbv2.k8s.aws/cluster = lab-sandbox keeps the grant to SGs the controller
  # created for THIS cluster.
  statement {
    sid = "Ec2DeleteControllerSecurityGroups"
    actions = [
      "ec2:DeleteSecurityGroup",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = [local.cluster]
    }
  }

  # --- IAM: the two sandbox roles and the cluster's OIDC provider only ----
  statement {
    sid = "IamSandboxRoles"
    actions = [
      "iam:GetRole", "iam:ListRoleTags", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:RemoveRoleFromInstanceProfile",
      "iam:DetachRolePolicy", "iam:DeleteRole",
      # Inline role policies (phase 1: lab-sandbox-litellm's Bedrock policy).
      # Refresh reads them; destroy deletes them before the role.
      "iam:GetRolePolicy", "iam:DeleteRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.cluster}-*"]
  }
  statement {
    sid = "IamSandboxOidc"
    actions = [
      "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviderTags",
      "iam:DeleteOpenIDConnectProvider",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/*",
    ]
  }
  # tofu/eks.tf looks this user up by name to grant its access entry, so a
  # destroy run by this user has to be able to read itself.
  statement {
    sid       = "IamReadSelf"
    actions   = ["iam:GetUser"]
    resources = [aws_iam_user.teardown.arn]
  }
}

# A MANAGED policy, attached, rather than an inline user policy. Inline user
# policies cap at 2048 bytes and this one passed that on 2026-09-22 when phase
# 2 added the security-group statements: PutUserPolicy failed with
# "LimitExceeded: Maximum policy size of 2048 bytes exceeded". Managed policies
# allow 6144, and the document is ~3.4 KB today.
#
# The cap is on the RENDERED JSON, so whitespace is not the problem and
# reformatting will not buy room. When phase 3 pushes this past 6144, the fix
# is a second managed policy (up to 10 can be attached), not wildcards that
# widen what this key can reach.
#
# This is still the only identity whose key sits on a lab node and on paper, so
# the scoping rules above do not change: read what destroy refreshes, delete
# only what tofu/ creates, create nothing.
resource "aws_iam_policy" "teardown" {
  name        = "eks-sandbox-teardown"
  path        = "/homelab-aws/"
  description = "Nightly EKS sandbox teardown. Destroys lab-sandbox; creates nothing."
  policy      = data.aws_iam_policy_document.teardown.json
}

resource "aws_iam_user_policy_attachment" "teardown" {
  user       = aws_iam_user.teardown.name
  policy_arn = aws_iam_policy.teardown.arn
}

output "teardown_user_arn" {
  value = aws_iam_user.teardown.arn
}

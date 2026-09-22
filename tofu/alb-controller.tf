# ---------------------------------------------------------------------------
# Phase 2: AWS Load Balancer Controller. The ingress half.
#
# What it does: watches Ingress objects and creates a real ALB for each one,
# outside Tofu's state. That is the whole reason this phase needs care -
# `tofu destroy` knows nothing about an ALB, and a VPC cannot be deleted while
# one still has ENIs in it. scripts/eks-teardown.sh handles the ordering
# (delete Ingresses -> wait for the load balancers to disappear -> destroy);
# this file just makes sure the controller can clean up after itself.
#
# Identity is IRSA again, exactly as tofu/litellm.tf explains it. The one
# difference: the Helm chart creates the ServiceAccount, not Tofu, because the
# chart wires the SA into its own Deployment. The role ARN still never reaches
# git - it is a Helm value here, not a manifest in gitops/.
# ---------------------------------------------------------------------------

locals {
  alb_controller_namespace = "kube-system"
  alb_controller_sa        = "aws-load-balancer-controller"
}

# --- The role ----------------------------------------------------------------

data "aws_iam_policy_document" "alb_controller_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:${local.alb_controller_namespace}:${local.alb_controller_sa}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  # lab-sandbox-* so the teardown policy's IamSandboxRoles statement covers it.
  name               = "${var.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_trust.json
}

# The controller's policy is upstream's, vendored VERBATIM and pinned to the
# chart version, rather than fetched at apply time from a URL that can change
# under us. Re-vendor deliberately when bumping the chart:
#
#   curl -fsS --proto '=https' --tlsv1.2 \
#     -o tofu/policies/alb-controller-v<NEW>.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v<NEW>/docs/install/iam_policy.json
#
# It is broader than this sandbox needs - it carries acm, cognito-idp, shield,
# waf-regional and wafv2 actions for features we disable in the Helm values
# below. Left intact so the file can be diffed against upstream; trimming it is
# a worthwhile exercise, but do that as its own change with its own test.
#
# Inline rather than a managed policy on purpose: the teardown identity can
# delete inline policies on lab-sandbox-* roles (iam:DeleteRolePolicy), but is
# deliberately not allowed to create or delete standalone IAM policies.
resource "aws_iam_role_policy" "alb_controller" {
  name   = "alb-controller"
  role   = aws_iam_role.alb_controller.id
  policy = file("${path.module}/policies/alb-controller-v3.5.0.json")
}

# --- The security group the ALB fronts ---------------------------------------
#
# WHY THIS EXISTS: left to itself, the controller creates the ALB's security
# group from the alb.ingress.kubernetes.io/inbound-cidrs annotation - which
# would put a home IP range in a PUBLIC git repo. Instead Tofu creates the SG
# from var.alb_allowed_cidrs (terraform.tfvars, gitignored) and the Ingress in
# gitops/ references it by NAME, which is stable and says nothing.
resource "aws_security_group" "alb_ingress" {
  name        = "${var.cluster_name}-alb-ingress"
  description = "Ingress ALB front end. Allowed sources come from var.alb_allowed_cidrs."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-alb-ingress"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_allowed_cidrs)

  security_group_id = aws_security_group.alb_ingress.id
  description       = "HTTP from an allowed source"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Egress to the targets. The controller manages the node side of this pair
# itself (a backend SG it creates and tags with the cluster name).
resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb_ingress.id
  description       = "To targets in the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

# --- The controller ----------------------------------------------------------

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version
  namespace  = local.alb_controller_namespace

  # The chart ships the IngressClassParams and TargetGroupBinding CRDs, and
  # creates the `alb` IngressClass. Nothing else needs to install them.
  values = [yamlencode({
    clusterName = aws_eks_cluster.this.name
    region      = var.region
    vpcId       = aws_vpc.this.id

    serviceAccount = {
      create = true
      name   = local.alb_controller_sa
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
      }
    }

    # One replica: a sandbox, and t3 spot capacity is better spent elsewhere.
    replicaCount = 1

    # Features this sandbox does not use. Off means the controller never calls
    # those APIs, so the broad grants in the vendored policy stay unused.
    enableShield = false
    enableWaf    = false
    enableWafv2  = false
  })]

  timeout = 600
  wait    = true

  # Same destroy-ordering rule as argocd: keep lab-teardown's cluster access
  # alive until this release is gone. See CLAUDE.md.
  depends_on = [
    aws_eks_node_group.spot,
    aws_eks_addon.coredns,
    aws_eks_addon.vpc_cni,
    aws_eks_access_policy_association.teardown,
  ]
}

output "alb_ingress_security_group" {
  description = "Name the gitops Ingress references in alb.ingress.kubernetes.io/security-groups."
  value       = aws_security_group.alb_ingress.name
}

# ---------------------------------------------------------------------------
# Phase 1: LiteLLM -> Bedrock via IRSA. The identity half.
#
# The workload (Deployment, Service, config) is GitOps, in
# gitops/workloads/litellm/. This file owns only the IDENTITY PLUMBING:
#   - an IAM role the pod can assume, and only that pod
#   - the namespace and ServiceAccount carrying the role annotation
#
# Why Tofu owns the ServiceAccount rather than git: the annotation is the
# role ARN, which contains the account ID. The repo is public. Keeping the SA
# here keeps the ARN out of git, and means the role and the only thing that
# references it are created and destroyed together.
#
# How IRSA works, end to end, because this is the lesson:
#   1. EKS runs an OIDC issuer for the cluster (tofu/iam.tf registers it
#      with IAM as aws_iam_openid_connect_provider.this).
#   2. The pod mounts a projected ServiceAccount token - a JWT signed by that
#      issuer, with sub = system:serviceaccount:litellm:litellm and
#      aud = sts.amazonaws.com.
#   3. EKS's pod-identity webhook sees the role-arn annotation and injects
#      AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE into the pod.
#   4. boto3 inside LiteLLM calls sts:AssumeRoleWithWebIdentity with the JWT.
#      STS checks the signature against the OIDC provider and the sub/aud
#      against the trust policy below, and returns ~1h credentials.
#   5. No access key exists anywhere. Nothing to leak, nothing to rotate.
# ---------------------------------------------------------------------------

locals {
  litellm_namespace = "litellm"
  litellm_sa        = "litellm"

  oidc_issuer_hostpath = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  # Claude Haiku 4.5. In us-east-1 the bedrock-runtime API REJECTS the bare
  # model ID for on-demand use; it must be called through the US inference
  # profile, which routes each request to one of three regions. The policy
  # must allow the profile AND the model in every destination region, or
  # calls fail intermittently depending on where a request is routed.
  bedrock_model_id           = "anthropic.claude-haiku-4-5-20251001-v1:0"
  bedrock_inference_profile  = "us.${local.bedrock_model_id}"
  bedrock_profile_dest_regns = ["us-east-1", "us-east-2", "us-west-2"]
}

# --- The role ----------------------------------------------------------------

data "aws_iam_policy_document" "litellm_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    # BOTH conditions, StringEquals, never StringLike on sub. Without the sub
    # pin, ANY ServiceAccount in the cluster could assume this role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:${local.litellm_namespace}:${local.litellm_sa}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "litellm" {
  # Must match lab-sandbox-* - the teardown policy is scoped to that prefix.
  name               = "${var.cluster_name}-litellm"
  assume_role_policy = data.aws_iam_policy_document.litellm_trust.json
}

data "aws_iam_policy_document" "litellm_bedrock" {
  statement {
    sid     = "InvokeHaikuViaUsProfile"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = concat(
      ["arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${local.bedrock_inference_profile}"],
      [for r in local.bedrock_profile_dest_regns : "arn:aws:bedrock:${r}::foundation-model/${local.bedrock_model_id}"],
    )
  }
  # Deliberately absent: aws-marketplace:Subscribe. The first-ever Anthropic
  # call in the account creates a Marketplace subscription and needs it; that
  # call is made once, by you, as admin (RUNBOOK "Phase 1"). The pod never
  # needs it.
}

resource "aws_iam_role_policy" "litellm_bedrock" {
  name   = "bedrock-invoke-haiku"
  role   = aws_iam_role.litellm.id
  policy = data.aws_iam_policy_document.litellm_bedrock.json
}

# --- The Kubernetes side -----------------------------------------------------

resource "kubernetes_namespace_v1" "litellm" {
  metadata {
    name = local.litellm_namespace
  }

  # Destroy runs in reverse dependency order. This edge keeps lab-teardown's
  # cluster access alive until the namespace (and the SA in it) are gone -
  # the same rule as helm_release.argocd. See CLAUDE.md.
  depends_on = [
    aws_eks_node_group.spot,
    aws_eks_access_policy_association.teardown,
  ]
}

resource "kubernetes_service_account_v1" "litellm" {
  metadata {
    name      = local.litellm_sa
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.litellm.arn
    }
  }
}

output "litellm_role_arn" {
  value = aws_iam_role.litellm.arn
}

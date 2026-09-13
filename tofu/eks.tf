resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
    # No public_access_cidrs. Decided deliberately: a residential IP is
    # dynamic, so pinning it means re-applying every time the WAN address
    # rotates, to add defence-in-depth to an endpoint that already requires
    # IAM auth. Revisit if a WireGuard box ever exists (Seam A).
  }

  access_config {
    # API, not API_AND_CONFIG_MAP. The aws-auth ConfigMap path is deprecated by
    # EKS, and access entries mean bootstrap never requires kubectl-ing into
    # the cluster to grant yourself access.
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# Extra admins (e.g. the n150-2 teardown identity, if it differs from yours).
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.extra_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.extra_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope { type = "cluster" }

  depends_on = [aws_eks_access_entry.admin]
}

# --- Nodes -----------------------------------------------------------------

resource "aws_eks_node_group" "spot" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id

  capacity_type  = "SPOT"
  instance_types = var.node_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"
  disk_size      = 30

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config { max_unavailable = 1 }

  # Node count is managed by Karpenter from phase 3 onward; without this the
  # next apply would fight the autoscaler and churn nodes.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# --- Addons ----------------------------------------------------------------
# vpc-cni before nodes (pods need networking to schedule at all); coredns
# after (it has replicas that cannot schedule on an empty cluster and the
# addon reports DEGRADED, failing the apply).

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.spot]
}

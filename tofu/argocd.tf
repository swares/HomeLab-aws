# ---------------------------------------------------------------------------
# Argo CD lives INSIDE this cluster and dies with it.
#
# The lab's Argo CD is not involved and never learns AWS exists. That is the
# entire point of the design: no cluster Secret to register, no rotating
# endpoint to write back into Vault, no static IAM credentials mounted into
# the lab control plane, and no Applications sitting Unknown in the lab UI
# every night after teardown.
#
# The cost is that EKS app status is not visible in lab Grafana. For a cluster
# that exists in 8-hour windows, that is the right trade.
# ---------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  # 10m because a spot nodegroup can take a while to place pods if the first
  # instance type is capacity-constrained.
  timeout = 600

  values = [yamlencode({
    # Single-replica everything. This is a sandbox, not an HA install.
    controller = { replicas = 1 }
    redis      = { enabled = true }
    server = {
      # No ingress, no LoadBalancer Service. Reach the UI with:
      #   kubectl -n argocd port-forward svc/argocd-server 8080:443
      #
      # This is not laziness - it is what keeps `tofu destroy` clean. The
      # moment a Service type=LoadBalancer or an Ingress exists, AWS creates
      # load balancers and security groups that tofu does not know about, and
      # destroying the VPC hangs on dependencies it cannot see. Ingress is
      # introduced deliberately in phase 2, with the ALB controller, so the
      # teardown-ordering lesson is learned on purpose.
      service   = { type = "ClusterIP" }
      extraArgs = ["--insecure"] # TLS terminates nowhere; port-forward is local
    }
    dex           = { enabled = false }
    notifications = { enabled = false }
    # No applicationSet key: since chart 6.9.0 the ApplicationSet controller
    # is always installed and `applicationSet.enabled` is silently ignored.
    # It was set to false here until 2026-09-21, which read as if it worked.

    # The app-of-apps root, injected as a chart extraObject.
    #
    # Why not a kubernetes_manifest resource: that provider validates against
    # the CRD at PLAN time, and the Application CRD does not exist until this
    # release is installed. Classic chicken-and-egg; extraObjects sidesteps it
    # because Helm renders it as part of the same release.
    extraObjects = [
      {
        apiVersion = "argoproj.io/v1alpha1"
        kind       = "Application"
        metadata = {
          name       = "root"
          namespace  = "argocd"
          finalizers = ["resources-finalizer.argocd.argoproj.io"]
        }
        spec = {
          project = "default"
          source = {
            repoURL        = var.gitops_repo_url
            targetRevision = var.gitops_revision
            path           = "gitops/apps"
            directory      = { recurse = true }
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated   = { prune = true, selfHeal = true }
            syncOptions = ["CreateNamespace=true"]
          }
        }
      }
    ]
  })]

  depends_on = [
    aws_eks_node_group.spot,
    aws_eks_addon.coredns,
    aws_eks_addon.vpc_cni,
  ]
}

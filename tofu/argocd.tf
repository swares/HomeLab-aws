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
  })]

  depends_on = [
    aws_eks_node_group.spot,
    aws_eks_addon.coredns,
    aws_eks_addon.vpc_cni,
    # LOAD-BEARING FOR THE NIGHTLY TEARDOWN, not for install. Destroy runs in
    # reverse dependency order, so this guarantees both Helm releases are
    # uninstalled while lab-teardown still has Kubernetes access. Without it,
    # tofu may delete the access entry in parallel with the uninstall, and the
    # timer's destroy fails Unauthorized halfway - cluster still up.
    aws_eks_access_policy_association.teardown,
  ]
}

# ---------------------------------------------------------------------------
# The app-of-apps root, as a SECOND Helm release (the argocd-apps chart).
#
# It cannot live in the argo-cd release above. Helm validates every object in
# a release against the cluster's API before installing any of them, and the
# Application CRD ships in that same release - so on a fresh cluster Helm
# fails with "no matches for kind Application ... ensure CRDs are installed
# first". Until 2026-09-21 the root was an `extraObjects` entry with a comment
# claiming it avoided exactly this; the first real apply proved otherwise.
#
# A kubernetes_manifest resource does not work either: that provider checks
# the CRD at PLAN time, before this cluster exists. A separate release that
# depends_on the first is the standard pattern, and it is what argoproj ships
# the argocd-apps chart for.
#
# Destroy order is the reverse: this release goes first, and the Application's
# finalizer cascades to everything Argo deployed. scripts/eks-teardown.sh
# deletes Applications before `tofu destroy` anyway, so this is belt and braces.
# ---------------------------------------------------------------------------

resource "helm_release" "argocd_root" {
  name      = "argocd-root"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      root = {
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        project    = "default"
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
  })]

  depends_on = [helm_release.argocd]
}

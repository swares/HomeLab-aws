output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "oidc_provider_arn" {
  description = "Trust anchor for IRSA roles in phase 1."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  value = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

output "kubeconfig_command" {
  description = "Writes to a dedicated file, never ~/.kube/config. `make eks-kubeconfig` runs this."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region} --kubeconfig ~/.kube/eks-sandbox"
}

output "argocd_ui" {
  value = <<-EOT
    make argocd-ui     (password + port-forward, using ~/.kube/eks-sandbox)
    then: http://localhost:8080  (user: admin)
  EOT
}

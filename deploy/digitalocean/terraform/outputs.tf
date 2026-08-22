output "cluster_id" {
  description = "DOKS cluster ID."
  value       = digitalocean_kubernetes_cluster.bank_of_anthos.id
}

output "cluster_name" {
  description = "DOKS cluster name (use with `doctl kubernetes cluster kubeconfig save`)."
  value       = digitalocean_kubernetes_cluster.bank_of_anthos.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = digitalocean_kubernetes_cluster.bank_of_anthos.endpoint
}

output "kubernetes_version" {
  description = "Kubernetes version running on the cluster."
  value       = digitalocean_kubernetes_cluster.bank_of_anthos.version
}

output "kubeconfig" {
  description = "Raw kubeconfig for the cluster. Prefer `doctl kubernetes cluster kubeconfig save <name>`; the token embedded here expires after 7 days."
  value       = digitalocean_kubernetes_cluster.bank_of_anthos.kube_config[0].raw_config
  sensitive   = true
}

output "container_registry_endpoint" {
  description = "DOCR endpoint (e.g. registry.digitalocean.com/<name>), empty when the registry is not managed here."
  value       = var.create_container_registry ? digitalocean_container_registry.bank_of_anthos[0].endpoint : ""
}

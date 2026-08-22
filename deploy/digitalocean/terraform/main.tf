data "digitalocean_kubernetes_versions" "current" {}

locals {
  kubernetes_version = var.kubernetes_version != "" ? var.kubernetes_version : data.digitalocean_kubernetes_versions.current.latest_version
}

resource "digitalocean_kubernetes_cluster" "bank_of_anthos" {
  name         = var.cluster_name
  region       = var.region
  version      = local.kubernetes_version
  tags         = var.tags
  auto_upgrade = false

  node_pool {
    name       = "${var.cluster_name}-default"
    size       = var.node_size
    tags       = var.tags
    auto_scale = var.auto_scale
    node_count = var.node_count
    min_nodes  = var.auto_scale ? var.min_nodes : null
    max_nodes  = var.auto_scale ? var.max_nodes : null
  }
}

resource "digitalocean_container_registry" "bank_of_anthos" {
  count                  = var.create_container_registry ? 1 : 0
  name                   = var.container_registry_name
  subscription_tier_slug = var.container_registry_tier
  region                 = var.region
}

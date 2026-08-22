variable "do_token" {
  description = "DigitalOcean API token with read/write access."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name of the DOKS cluster."
  type        = string
  default     = "bank-of-anthos"
}

variable "region" {
  description = "DigitalOcean region slug for the cluster (e.g. nyc1, sfo3, fra1)."
  type        = string
  default     = "nyc1"
}

variable "kubernetes_version" {
  description = "DOKS Kubernetes version slug (e.g. 1.31.1-do.0). Run `doctl kubernetes options versions` to list valid slugs. Leave empty to use the latest version available in the region."
  type        = string
  default     = ""
}

variable "node_size" {
  description = "Droplet size slug for the default node pool. Bank of Anthos needs ~4 vCPU / 8 GB across the pool."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "node_count" {
  description = "Number of nodes in the default node pool (ignored when autoscaling is enabled)."
  type        = number
  default     = 3
}

variable "auto_scale" {
  description = "Enable autoscaling on the default node pool."
  type        = bool
  default     = false
}

variable "min_nodes" {
  description = "Minimum node count when autoscaling is enabled."
  type        = number
  default     = 2
}

variable "max_nodes" {
  description = "Maximum node count when autoscaling is enabled."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags applied to the cluster and node pool."
  type        = list(string)
  default     = ["bank-of-anthos"]
}

variable "create_container_registry" {
  description = "Create a DigitalOcean Container Registry (DOCR) for the service images. Only one registry per DO account is allowed, so set this to false if you already have one."
  type        = bool
  default     = false
}

variable "container_registry_name" {
  description = "Globally unique name for the DOCR registry (used when create_container_registry is true)."
  type        = string
  default     = "bank-of-anthos"
}

variable "container_registry_tier" {
  description = "DOCR subscription tier: starter, basic, or professional."
  type        = string
  default     = "basic"
}

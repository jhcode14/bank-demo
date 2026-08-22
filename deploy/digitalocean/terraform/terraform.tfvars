# Non-secret deployment config, shared by local runs and CI.
# The API token is NOT set here: export TF_VAR_do_token=dop_v1_... locally, and
# in GitHub Actions it comes from the DIGITALOCEAN_ACCESS_TOKEN secret.
cluster_name = "bank-of-anthos"
region       = "nyc1"
node_size    = "s-2vcpu-4gb"
node_count   = 3

create_container_registry = true
container_registry_name   = "bank-of-anthos"
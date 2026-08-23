# Bank of Anthos on DigitalOcean Kubernetes (DOKS)

This directory contains an alternative, self-contained deployment path for
DigitalOcean. Nothing here depends on GCP: no GKE, Anthos Service Mesh, Config
Management, Cloud SQL, Workload Identity, Cloud Build or `gcloud`. The original
GCP assets (`kubernetes-manifests/`, `iac/`, `.github/cloudbuild/`,
`skaffold.yaml`) are untouched and still usable.

```
deploy/digitalocean/
├── kubernetes-manifests/   DOKS-ready copies of the upstream manifests
├── kustomize/              optional overlay for retagging images to DOCR
└── terraform/              DOKS cluster (+ optional DOCR) provisioning
```

CI/CD lives in [`.github/workflows/deploy-digitalocean.yml`](../../.github/workflows/deploy-digitalocean.yml).

## What differs from the GCP manifests

| Change | Why |
| --- | --- |
| `ENABLE_TRACING: "false"` in every deployment | Cloud Trace exporters (Python services) need GCP credentials/API. |
| `ENABLE_METRICS: "false"` on `balancereader`, `ledgerwriter`, `transactionhistory` | The Java services register a `StackdriverMeterRegistry` that reads the GCE metadata server, which does not exist on DOKS. |
| `iam.gke.io/gcp-service-account` annotation removed from the `bank-of-anthos` ServiceAccount (`config.yaml`) | Workload Identity is GKE-only. The ServiceAccount is kept because the deployments reference it. |
| `proxy.istio.io/config` pod annotation removed everywhere | No Istio/ASM sidecar injection on this path. |
| `frontend` Service left as `type: LoadBalancer` | DOKS provisions a DigitalOcean Load Balancer automatically. |
| `accounts-db` / `ledger-db` StatefulSets left as-is | In-cluster PostgreSQL, so no managed database is needed for a first deployment. |

Everything else (probes, resources, security contexts, ConfigMaps, JWT key
mount) is identical to the upstream manifests.

## Prerequisites

- `doctl`, `kubectl`, `terraform`, `docker`, JDK 17 + Maven (only for building
  the Java services locally)
- A DigitalOcean API token with read/write scope: `export DIGITALOCEAN_ACCESS_TOKEN=dop_v1_...`

## 1. Provision the cluster

```bash
cd deploy/digitalocean/terraform
export TF_VAR_do_token=$DIGITALOCEAN_ACCESS_TOKEN
terraform init
terraform apply
```

`terraform.tfvars` holds the non-secret settings (cluster name, region, node
size/count, registry) and is committed on purpose so local runs and CI agree.
The API token is never stored there — pass it via `TF_VAR_do_token`; in GitHub
Actions it comes from the `DIGITALOCEAN_ACCESS_TOKEN` secret.

Configurable inputs: `cluster_name`, `region`, `kubernetes_version`,
`node_size`, `node_count` (or `auto_scale` + `min_nodes`/`max_nodes`), `tags`,
and `create_container_registry` / `container_registry_name` /
`container_registry_region` / `container_registry_tier` for an optional DOCR
registry (DigitalOcean allows one registry per account, so leave it `false` if
you already have one). DOCR only exists in `nyc3`, `sfo3`, `ams3`, `fra1`,
`sgp1`, `blr1` and `syd1`, so its region is a separate variable from the cluster
region — a `nyc1` cluster pairs with an `nyc3` registry.

If the cluster or registry already exists (for example created by an earlier
local apply whose state is not in the remote backend), import it instead of
letting apply fail with `a cluster with this name already exists`:

```bash
terraform import digitalocean_kubernetes_cluster.bank_of_anthos "$(doctl kubernetes cluster get <cluster-name> --format ID --no-header)"
terraform import 'digitalocean_container_registry.bank_of_anthos[0]' <registry-name>
```

Outputs: `cluster_id`, `cluster_name`, `cluster_endpoint`, `kubernetes_version`,
`kubeconfig` (sensitive) and `container_registry_endpoint`.

Then fetch credentials:

```bash
doctl kubernetes cluster kubeconfig save "$(terraform output -raw cluster_name)"
kubectl get nodes
```

`kubectl` needs ~4 vCPU / 8 GB of allocatable capacity across the pool for the
full app; the default is three `s-2vcpu-4gb` nodes.

## 2. Container images (optional but recommended)

The manifests still reference the upstream public images at
`us-central1-docker.pkg.dev/bank-of-anthos-ci/bank-of-anthos/...` (pinned by
digest). If those remain publicly pullable, the manifests work unchanged on
DOKS. **If the registry is not public — or you want to run your own builds — the
images must be rebuilt and pushed to DOCR** (or any registry you control) and
the manifests retargeted.

Build and push manually:

```bash
export REGISTRY=registry.digitalocean.com/<your-registry>
export TAG=$(git rev-parse --short HEAD)
doctl registry login

# Dockerfile-based services
for svc in accounts/accounts-db accounts/contacts accounts/userservice \
           frontend ledger/ledger-db loadgenerator; do
  name=$(basename "$svc")
  docker build -t "$REGISTRY/$name:$TAG" "src/$svc"
  docker push "$REGISTRY/$name:$TAG"
done

# Java ledger services use Jib (no Dockerfile)
for m in balancereader ledgerwriter transactionhistory; do
  ./mvnw -f "src/ledger/$m/pom.xml" compile jib:build -Dimage="$REGISTRY/$m:$TAG"
done

# Let the cluster pull from DOCR
doctl kubernetes cluster registry add <cluster-name>

# That integration only patches each namespace's *default* ServiceAccount, but
# most services run as bank-of-anthos, so give that SA the same pull secret
# (DigitalOcean names the secret after the registry)
secret=$(kubectl get serviceaccount default -o jsonpath='{.imagePullSecrets[0].name}')
kubectl patch serviceaccount bank-of-anthos \
  -p "{\"imagePullSecrets\":[{\"name\":\"$secret\"}]}"
```

Without that patch the pods sit in `ImagePullBackOff` and the rollout ends with
`deployment "frontend" exceeded its progress deadline`. Pods already created
before the patch need
`kubectl get deployment,statefulset -o name | xargs kubectl rollout restart`,
since `imagePullSecrets` are only resolved at pod creation.

DOCR tiers also cap repository count: the app has nine images, so `basic`
(5 repos) is not enough — use `professional`, or push fewer services.

Retarget the manifests either with the kustomize overlay in
[`kustomize/kustomization.yaml`](kustomize/kustomization.yaml) (replace
`<REGISTRY>` and the tags, then
`kustomize build --load-restrictor LoadRestrictionsNone deploy/digitalocean/kustomize | kubectl apply -f -`
— the flag is needed because the overlay reads the manifests from the sibling
directory) or with `sed`:

```bash
sed -i -E "s|image: us-central1-docker\.pkg\.dev/bank-of-anthos-ci/bank-of-anthos/([^:@[:space:]]+)(:[^@[:space:]]+)?(@sha256:[a-f0-9]+)?|image: $REGISTRY/\1:$TAG|" \
  deploy/digitalocean/kubernetes-manifests/*.yaml
```

## 3. Deploy

The services need the RSA key pair used to sign JWTs, as a secret named
`jwt-key` (the upstream repo ships one at `extras/jwt/jwt-secret.yaml`; generate
your own for anything non-demo):

```bash
kubectl apply -f extras/jwt/jwt-secret.yaml
# or generate a fresh key pair:
#   openssl genrsa -out jwtRS256.key 4096
#   openssl rsa -in jwtRS256.key -pubout -out jwtRS256.key.pub
#   kubectl create secret generic jwt-key --from-file=jwtRS256.key --from-file=jwtRS256.key.pub
```

Validate and apply:

```bash
kubectl apply --dry-run=client -f deploy/digitalocean/kubernetes-manifests/
kubectl apply -f deploy/digitalocean/kubernetes-manifests/
kubectl get pods -w
```

## 4. Access the app

```bash
kubectl get service frontend
# EXTERNAL-IP is the DigitalOcean Load Balancer address
open "http://$(kubectl get service frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
```

Provisioning the load balancer takes a couple of minutes; until then
`EXTERNAL-IP` stays `<pending>`. Log in with the demo credentials from the
`demo-data-config` ConfigMap (`testuser` / `bankofanthos`).

## 5. Remote Terraform state (needed for CI provisioning)

State is local by default. To share it between your machine and GitHub Actions,
use a DigitalOcean Space (S3-compatible):

```bash
cd deploy/digitalocean/terraform
cp backend-spaces.tf.example backend.tf
export AWS_ACCESS_KEY_ID=<spaces key> AWS_SECRET_ACCESS_KEY=<spaces secret>
terraform init -migrate-state \
  -backend-config="bucket=<space name>" \
  -backend-config="key=bank-of-anthos/terraform.tfstate" \
  -backend-config='endpoints={s3="https://nyc3.digitaloceanspaces.com"}'
```

Spaces has no DynamoDB-style locking, so avoid concurrent applies.

## 6. CI/CD (GitHub Actions)

[`.github/workflows/deploy-digitalocean.yml`](../../.github/workflows/deploy-digitalocean.yml)
is a `workflow_dispatch` pipeline that replaces the Cloud Build flow. It
authenticates with `digitalocean/action-doctl` using the
`DIGITALOCEAN_ACCESS_TOKEN` repository secret, builds every service (Dockerfiles
under `src/**`, Jib for the Java ledger services), pushes to DOCR, runs
`doctl kubernetes cluster kubeconfig save`, creates the `jwt-key` secret if it is
missing, rewrites the image refs to the freshly pushed tags, and applies
`deploy/digitalocean/kubernetes-manifests/`. Inputs: `cluster_name`,
`registry_name`, `namespace`, `provision_infra`. No skaffold, `gcloud` or fleet
memberships.

With `provision_infra=true` an extra `terraform` job runs the module above
before deploying, taking the token from `DIGITALOCEAN_ACCESS_TOKEN` and the
state backend from these additional secrets:

| Secret | Value |
| --- | --- |
| `SPACES_BUCKET` | Space holding the state file |
| `SPACES_ENDPOINT` | e.g. `https://nyc3.digitaloceanspaces.com` |
| `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY` | Spaces access keys |

The job fails fast if they are missing, because with empty state Terraform would
try to create a second cluster on every run. Left at the default
`provision_infra=false`, the workflow only builds and deploys against an
existing cluster.

## Notes and limitations

- **Observability**: Cloud Trace (`ENABLE_TRACING`) and Stackdriver metrics
  (`ENABLE_METRICS`) are disabled — those code paths require GCP credentials and
  the GCE metadata server. Application source under `src/**` is unmodified; the
  env vars alone gate the exporters. For observability on DOKS, use
  DigitalOcean's cluster monitoring or install Prometheus/Grafana (see
  `extras/prometheus/`).
- **Workload Identity** is not used; the `bank-of-anthos` ServiceAccount is a
  plain Kubernetes ServiceAccount with no cloud IAM binding.
- **Databases**: the in-cluster PostgreSQL StatefulSets (`accounts-db`,
  `ledger-db`) are used, backed by DOKS block-storage PVCs. To move to
  DigitalOcean Managed Databases, point the connection URIs in the
  `accounts-db-config` and `ledger-db-config` ConfigMaps (defined in
  `kubernetes-manifests/accounts-db.yaml` and
  `kubernetes-manifests/ledger-db.yaml`) at the managed instance, seed the
  schema, and delete the StatefulSets. The managed cluster must be reachable
  from the DOKS VPC and the DB user/password kept in a Secret.
- **TLS/domains**: the frontend is served over plain HTTP through the DO Load
  Balancer. Add cert-manager or a DO-managed certificate on the load balancer
  for HTTPS; the GKE-specific `extras/tls-*` manifests do not apply here.

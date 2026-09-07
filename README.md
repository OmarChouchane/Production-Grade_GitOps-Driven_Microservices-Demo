# Production-Grade GitOps-Driven Microservices Demo

Online Boutique (11-service polyglot e-commerce app, gRPC internally) deployed to **Amazon EKS** through a GitOps pipeline: Terraform for infra, GitHub Actions for CI, Argo CD + Argo CD Image Updater for CD, AWS Gateway API/ALB for ingress, kube-prometheus-stack for metrics/alerting, and ECK for centralized logging.

| Layer | Tooling |
|---|---|
| IaC | Terraform, `terraform-aws-modules/eks` v21, `terraform-aws-modules/vpc` |
| Runtime | Amazon EKS 1.34, `t3.medium` managed node group |
| Ingress | Gateway API v1.3.0, AWS Load Balancer Controller v3.0.0 (ALB) |
| DNS | ExternalDNS 1.20.0, Route53, EKS Pod Identity |
| Packaging | Helm (OCI chart in GHCR), Kustomize (glue manifests only) |
| CI | GitHub Actions, Docker Buildx (GHA cache), Trivy, GHCR |
| CD | Argo CD 9.4.0, Argo CD Image Updater 1.0.5 |
| Metrics/Alerts | kube-prometheus-stack 81.6.3, Alertmanager → Slack |
| Logging | ECK operator 3.3.0 (Elasticsearch, Filebeat, Kibana), AWS EBS CSI driver |
| Autoscaling | metrics-server 3.13.0, HPA (`autoscaling/v2`) |

## Architecture

<!-- TODO: replace with your own diagram, e.g. docs/images/architecture.png -->
![Architecture Diagram](docs/images/architecture.png)

```
Internet
   │
   ▼
AWS ALB (Gateway API: app-alb-gateway)
   │  HTTPRoute per app (frontend / argocd / grafana / prometheus / kibana)
   ▼
EKS private subnets (3 AZ) ── frontend → cartservice / productcatalogservice /
                                          currencyservice / adservice /
                                          recommendationservice / checkoutservice
                                            └─ paymentservice / shippingservice / emailservice
                                          cartservice → Redis (in-cluster)
```

CI/CD control loop:

```
git push (src/**) → GitHub Actions (matrix build, per changed service)
                   → Trivy scan → push image:sha-<commit> to GHCR
                                    │
                                    ▼
                   Argo CD Image Updater (newest-build strategy)
                                    │  patches Argo CD Application
                                    ▼
                   Argo CD (auto-sync, prune, selfHeal)
                                    │  renders: helm-chart (OCI) + kustomization.yaml
                                    ▼
                   EKS cluster, namespace boutique-app
```

## Application

11 services, gRPC internally (`protos/demo.proto`), one Helm chart. Only `cartservice` persists state.

| Service | Language | Notes |
|---|---|---|
| `frontend` | Go | HTTP entrypoint, generates session cookies |
| `cartservice` | C# | Redis-backed cart |
| `productcatalogservice` | Go | Static JSON product catalog, in-memory |
| `currencyservice` | Node.js | Highest-QPS service, static FX rates |
| `paymentservice` | Node.js | Mock charge, returns a transaction ID |
| `shippingservice` | Go | Mock shipping quote |
| `emailservice` | Python | Mock order-confirmation email |
| `checkoutservice` | Go | Orchestrates cart → payment → shipping → email |
| `recommendationservice` | Python | Recommends products from cart contents |
| `adservice` | Java | Context-keyed text ads, in-memory |
| `loadgenerator` | Python/Locust | Synthetic traffic against `frontend` |

## Repository layout

```
src/                                  service source + Dockerfiles + protos
terraform/                            VPC, EKS, bastion host (applied manually, not via pipeline)
gateway-api-manifests/                GatewayClass, LoadBalancerConfiguration, Gateway
external-dns/                         IAM policy + Helm values for ExternalDNS
argocd/                               Argo CD install values, Application, Image Updater CR
helm-chart/                           application Helm chart (packaged as OCI, pushed to GHCR)
microservices-extra-kube-manifests/   HTTPRoute + TargetGroupConfiguration for the app
observability/                        Prometheus/Alertmanager/Grafana + ECK stack values
scaling/                              HorizontalPodAutoscaler manifests
kustomization.yaml                    Argo CD entrypoint: wraps the Helm chart + extra manifests
docs/images/                          README assets
.github/workflows/                    CI: change-detection + reusable build/scan/push workflow
```

## Infrastructure

`terraform/` provisions:

- VPC (`10.0.0.0/16`, 3 AZs, public + private subnets, single NAT gateway)
- EKS cluster (`terraform-cluster`, k8s 1.34), managed node group `t3.medium` (min 2 / max 5 / desired 2), add-ons: `coredns`, `kube-proxy`, `vpc-cni`, `eks-pod-identity-agent`
- API endpoint is **private** (`endpoint_public_access = false`) — cluster is only reachable from inside the VPC
- Bastion EC2 host in the public subnet, SSH locked to the operator's current IP, used as the jump box for all `kubectl`/`helm` operations

State is local by default; the Terraform config supports an S3 backend (versioned + SSE-encrypted bucket) for team use — see `terraform/terraform.tf`.

```bash
cd terraform
terraform init
terraform apply
```

## Networking

Ingress uses **Gateway API**, not Ingress:

- `GatewayClass` → AWS Load Balancer Controller (`controllerName: gateway.k8s.aws/alb`)
- `Gateway` (`app-alb-gateway`) → provisions one shared ALB, HTTP/HTTPS listeners, wildcard hostname
- `HTTPRoute` per app → attaches to the Gateway, routes by hostname to a Service
- `TargetGroupConfiguration` per Service → required whenever the ALB registers pod IPs directly (`targetType: ip`); not needed for mesh/in-cluster proxies

`external-dns` watches `Gateway`/`HTTPRoute` objects and syncs Route53 automatically, authenticating via EKS Pod Identity (no static AWS keys).

## CI

`.github/workflows/ci-trigger.yaml` diffs the pushed commit range, extracts changed service directories under `src/`, and fans out a build matrix into the reusable workflow `microservice-ci.yaml`, which per service:

1. `docker buildx build` with GitHub Actions layer cache
2. Trivy image scan (`HIGH,CRITICAL`) — currently **advisory only** (`exit-code: 0`); flip to `1` to hard-fail the pipeline on critical CVEs
3. Push to `ghcr.io/<owner>/microservices-demo/<service>:sha-<commit>`

Only changed services rebuild — untouched services are skipped entirely.

## CD

Argo CD watches this repo and reconciles `kustomization.yaml`, which combines:

- the packaged Helm chart (`oci://ghcr.io/<org>/onlineboutique`, values from `helm-chart/values.yaml`)
- `microservices-extra-kube-manifests/` (HTTPRoute + TargetGroupConfiguration — environment-specific, deliberately kept out of the portable Helm chart)

`syncPolicy.automated` runs with `prune: true, selfHeal: true` — any manual `kubectl edit`/`apply` against the cluster is reverted on the next reconciliation loop. Git is the only durable source of truth.

Argo CD Image Updater closes the loop between CI and CD: it polls GHCR, filters tags with `allowTags: regexp:^sha-[a-f0-9]{7,40}$`, and applies `updateStrategy: newest-build`, patching the running `Application` via the Argo CD API. This is **live-state update mode** (no Git write-back) — acceptable here because the registry is public and no bot-commit credentials are provisioned; a stricter setup would use write-back mode so Git also reflects the deployed tag.

Observability is deliberately **not** managed by Argo CD — it's installed via direct `helm upgrade -i` from the bastion, so the monitoring/alerting stack's trust boundary stays independent of the deployment pipeline it's supposed to be watching.

## Observability

**Metrics & alerting** — kube-prometheus-stack (Prometheus, Alertmanager, Grafana). Alert routing groups by `namespace`, routes `severity=critical` to Slack via a webhook mounted from a Kubernetes Secret (never inlined in `values.yaml`). Grafana and Prometheus are each exposed with their own `HTTPRoute` + `TargetGroupConfiguration` since the chart doesn't template Gateway API resources.

**Logging** — ECK operator manages `Elasticsearch`, `Filebeat` (DaemonSet, Kubernetes autodiscover, `hostNetwork: true`), and `Kibana` CRs. Elasticsearch requires the AWS EBS CSI driver + a dedicated `StorageClass` (`ebs-aws`, `WaitForFirstConsumer`) for its PVC — the only disk-backed component in the stack.

```bash
kubectl get pods -n monitoring
kubectl get pods -n logging
```

## Scaling

`scaling/` defines HPAs (`autoscaling/v2`) on the hot-path services: `frontend`, `cartservice`, `checkoutservice`, `recommendationservice`. Requires `metrics-server` and CPU `requests` set on each Deployment (utilization % is relative to requests, not absolute).

```bash
kubectl get hpa -n boutique-app -w
```

Scaling config changes must go through Git (Helm values), not `kubectl edit` — Argo CD will revert live drift.

## Getting started

Prerequisites: AWS CLI configured, Terraform, an IAM user with EKS/VPC/EC2/IAM permissions.

```bash
# 1. Infra
cd terraform && terraform init && terraform apply

# 2. From the bastion host
aws eks update-kubeconfig --region us-east-1 --name terraform-cluster
kubectl get nodes

# 3. AWS Load Balancer Controller + Gateway API CRDs
#    see README history / gateway-api-manifests/ for exact install commands

# 4. Argo CD
helm install argo-cd argo/argo-cd -n argocd -f argocd/argocd-values-9.4.0.yaml --create-namespace
kubectl apply -f argocd/argocd-apps/boutique-app.yaml

# 5. Argo CD Image Updater
helm install argocd-image-updater argo/argocd-image-updater -n argocd
kubectl apply -f argocd/image-updater.yaml

# 6. Observability (installed directly, outside Argo CD)
helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -f observability/helm-values/kube-prom-stack-81.6.3.yaml -n monitoring --create-namespace
```

## Teardown

```bash
# delete the ALB and its security groups first (Kubernetes doesn't always clean these up)
terraform destroy -auto-approve
```

## Known limitations

- Single NAT gateway — no AZ redundancy for outbound traffic
- Redis for the cart is a single, unreplicated pod — cart data is lost on pod deletion
- Bastion relies on a standing SSH key rather than SSM Session Manager
- Image Updater runs in live-state mode; Git and cluster state can briefly diverge
- Trivy scan is advisory (`exit-code: 0`), not a hard gate

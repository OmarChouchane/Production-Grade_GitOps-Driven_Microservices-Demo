# Production-Grade GitOps-Driven Microservices Demo

A hands-on DevOps project that takes the [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) e-commerce demo — 11 microservices across 7 languages, talking over gRPC — and deploys it to **Amazon EKS** using a full production-style GitOps stack: Terraform, GitHub Actions, Argo CD, Gateway API, Prometheus/Grafana, and the ECK logging stack.

## Architecture

<!-- TODO: drop your architecture diagram here, e.g. docs/images/architecture.png -->
![Architecture Diagram](docs/images/architecture.png)

## The application

| Service | Language | Role |
|---|---|---|
| frontend | Go | Serves the website, generates sessions |
| cartservice | C# | Stores cart items in Redis |
| productcatalogservice | Go | Product list & search |
| currencyservice | Node.js | Currency conversion |
| paymentservice | Node.js | Mock payment charge |
| shippingservice | Go | Shipping cost estimate |
| emailservice | Python | Mock order confirmation email |
| checkoutservice | Go | Orchestrates cart, payment, shipping, email |
| recommendationservice | Python | Product recommendations |
| adservice | Java | Context-based text ads |
| loadgenerator | Python/Locust | Simulates shopper traffic |

Only `cartservice` is stateful (Redis). Everything else is stateless by design, keeping the demo focused on platform concerns rather than data modeling.

## Platform stack

- **Infrastructure** — Terraform provisions the VPC, EKS cluster, and a bastion host (`terraform/`)
- **Networking** — Kubernetes Gateway API on an AWS ALB, with ExternalDNS syncing Route53 (`gateway-api-manifests/`, `external-dns/`)
- **CI** — GitHub Actions builds and Trivy-scans only the services that changed, then pushes to GHCR (`.github/workflows/`)
- **CD** — Argo CD reconciles the cluster from Git (Helm chart + Kustomize glue), with Argo CD Image Updater picking up new image tags automatically (`argocd/`, `helm-chart/`, `kustomization.yaml`)
- **Observability** — kube-prometheus-stack for metrics/alerts to Slack, ECK (Elasticsearch/Filebeat/Kibana) for centralized logging (`observability/`)
- **Scaling** — HorizontalPodAutoscaler on the hot-path services (`scaling/`)

## Repository layout

```
src/                              application source code (11 services) + protobuf contracts
terraform/                        VPC, EKS cluster, bastion host
gateway-api-manifests/            Gateway API: GatewayClass, LoadBalancerConfiguration, Gateway
external-dns/                     ExternalDNS IAM policy & Helm values
argocd/                           Argo CD install values, Application manifests, Image Updater config
helm-chart/                       packaged Helm chart deployed by Argo CD
microservices-extra-kube-manifests/  HTTPRoute + TargetGroupConfiguration for the app
observability/                    Prometheus/Grafana/Alertmanager + ECK logging stack values
scaling/                          HorizontalPodAutoscaler manifests
kustomization.yaml                root entrypoint Argo CD points at (wraps the Helm chart)
docs/                             screenshots used in this README
```

## Quick start

```bash
# 1. Provision infrastructure
cd terraform
terraform init
terraform apply

# 2. SSH into the bastion host, then configure kubectl
aws eks update-kubeconfig --region <region> --name terraform-cluster

# 3. Install the AWS Load Balancer Controller, Gateway API CRDs, and ExternalDNS
#    (see individual manifests under gateway-api-manifests/ and external-dns/)

# 4. Install Argo CD and apply the Application
kubectl apply -f argocd/argocd-apps/boutique-app.yaml

# 5. Install the observability stack (kept outside Argo CD on purpose)
helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -f observability/helm-values/kube-prom-stack-81.6.3.yaml -n monitoring
```

Full step-by-step setup (including Slack alerting and ECK logging) lives in the commit history / project notes — this README stays intentionally short as a reference, not a tutorial.

## Cleanup

```bash
terraform destroy -auto-approve
```

Remember to delete the load balancer and its security groups first if it wasn't cleaned up by Kubernetes.

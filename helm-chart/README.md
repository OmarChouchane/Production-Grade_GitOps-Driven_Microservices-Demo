# Helm chart for Online Boutique

This chart is deployed by Argo CD as an OCI artifact from GHCR — see the root
[`kustomization.yaml`](../kustomization.yaml) for how it's wired into the GitOps flow.
It's a fork of [Google's Online Boutique chart](https://github.com/GoogleCloudPlatform/microservices-demo/tree/main/helm-chart),
retargeted at AWS (GHCR images, Redis-only cart storage, no Spanner/GKE-specific flags).

Install directly (no Argo CD):
```sh
helm install onlineboutique oci://ghcr.io/omarchouchane/onlineboutique \
    --version 0.10.4 \
    --create-namespace \
    -n boutique-app
```

For the full list of configuration knobs, see [values.yaml](./values.yaml).
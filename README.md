# talos-gitops

GitOps repository managing Kubernetes workloads and platform services on a Talos Linux cluster using Argo CD.

## Repository Layout

```text
talos-gitops/
├── bootstrap/          # Cluster bootstrap manifests
│   ├── argocd-values.yaml  # Helm values for Argo CD installation
│   └── root.yaml           # App-of-apps root Application
├── argocd-apps/        # Argo CD Applications managed by root.yaml
│   ├── sealed-secrets.yaml # Sync-wave -2: Secret decryption controller
│   ├── monitoring.yaml     # Sync-wave -1: kube-prometheus-stack
│   └── demo-app.yaml       # Sync-wave 1: Application workload
├── platform/           # Platform-level stack configurations
│   └── monitoring/         # Custom Helm values and SealedSecrets
│       ├── values.yaml     # Prometheus, Alertmanager, and Grafana config
│       └── secrets/        # Kustomization directory for sealed secrets
└── apps/               # Application manifests
    └── demo-app/           # Kustomize package for talos-demo-app
        ├── deployment.yaml
        ├── service.yaml
        ├── servicemonitor.yaml
        ├── prometheusrule.yaml
        └── kustomization.yaml
```

## Architecture and Sync Waves

Applications are coordinated through Argo CD sync waves to ensure dependencies are ready before dependent components start:

1. **Wave -2 (`sealed-secrets`)**: Deploys the Bitnami Sealed Secrets controller in `kube-system`. Decrypts sealed secrets needed by subsequent services.
2. **Wave -1 (`monitoring`)**: Deploys `kube-prometheus-stack` (v92.2.0) using multi-source Helm charts. Configured specifically for Talos Linux (disables localhost-bound scrapes for etcd and control plane components) and provisions Telegram alerting receivers for Alertmanager and Grafana.
3. **Wave 1 (`demo-app`)**: Deploys the demo microservice, ServiceMonitor, and Prometheus alerting rules after monitoring CRDs are established.

## Cluster Bootstrap

### 1. Install Argo CD

Install Argo CD into the `argocd` namespace using the provided values file:

```bash
helm install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version 10.10.1 \
  -n argocd \
  --create-namespace \
  -f bootstrap/argocd-values.yaml
```

### 2. Apply Root Application

Apply the root Application to start the App-of-Apps synchronization:

```bash
kubectl apply -f bootstrap/root.yaml
```

### 3. Configure Secrets

The cluster relies on Sealed Secrets for sensitive credentials. Once the Sealed Secrets controller is active, encrypt and commit required secrets:

- **Monitoring secrets** (`platform/monitoring/secrets/`):
  - `telegram-bot`: Contains `bot-token` for Alertmanager and Grafana Telegram notifications.
  - `grafana-admin`: Contains `admin-user` and `admin-password`.
- **Demo app secret** (`apps/demo-app/`):
  - `ghcr-pull`: Docker registry credentials for pulling images from private GHCR repositories.

## Accessing Services

In the default lab configuration, services are accessed via port forwarding:

```bash
# Argo CD UI (https://localhost:8080)
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Grafana UI (http://localhost:3000)
kubectl port-forward -n monitoring svc/kps-grafana 3000:80

# Demo App (http://localhost:8082)
kubectl port-forward -n demo svc/demo-app 8082:80
```

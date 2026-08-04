# Local Kubernetes (kind / k3d) — no remote cluster yet

Use this when you want to exercise the shared `helm/gym-service` chart with Istio.
CD from GitHub Actions is intentionally **not** enabled until a real cluster exists.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/) or [k3d](https://k3d.io/)
- `kubectl`, `helm` ≥ 3.12
- [istioctl](https://istio.io/latest/docs/setup/getting-started/) matching your target Istio minor

## 1. Create cluster

```bash
# kind
kind create cluster --name gym

# or k3d
k3d cluster create gym --agents 1
```

## 2. Install Istio (sidecar demo profile)

```bash
istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled --overwrite
# or deploy into a dedicated namespace:
kubectl create namespace gym-system
kubectl label namespace gym-system istio-injection=enabled --overwrite
```

## 3. Install a service with the shared chart

Charts live in this repo only. Other services pass a values overlay — they do **not** carry their own chart.

```bash
cd /path/to/gym-infra

helm upgrade --install ms-gym-member ./helm/gym-service \
  -n gym-system --create-namespace \
  -f ./helm/gym-service/examples/ms-gym-member-values.yaml \
  --set image.tag=develop
```

Go sample health paths:

```bash
helm upgrade --install go-service ./helm/gym-service \
  -n gym-system \
  -f ./helm/gym-service/examples/go-service-values.yaml
```

## 4. Reach the mesh gateway

```bash
kubectl -n istio-system get svc istio-ingressgateway
# kind/k3d often need port-forward:
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80
curl -H "Host: member.gym.local" http://127.0.0.1:8080/
```

## 5. What CI already does

| Workflow | Purpose |
|----------|---------|
| `go-ci.yml` | Lint + unit + coverage gate (callable) |
| `java-ci.yml` | Spotless + Gradle check / JaCoCo (callable) |
| `docker-build.yml` | Build/push GHCR; prune to max 20 versions |
| `helm-validate.yml` | `helm lint` + `helm template` only |

From another repo:

```yaml
jobs:
  java-ci:
    uses: pploc/gym-infra/.github/workflows/java-ci.yml@develop
    with:
      service_path: .
      gradle_args: check
    secrets: inherit
```

## 6. When a real cluster exists

- Point Argo CD / Flux at this chart + per-service values files, **or**
- Add a deploy workflow with kubeconfig — not scaffolded here on purpose.

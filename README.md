# Gym Infra

Shared DevOps for Gym microservices: **one generic Helm chart**, callable GitHub Actions, Kong local fixture, sample Go/Java services.

Other service repos **import** these assets — they do not vendor a private chart/CI copy.

## Layout

```
gym-infra/
├── .github/workflows/
│   ├── ci.yml              # this repo's pipeline
│   ├── go-ci.yml           # workflow_call — Go lint/test/coverage
│   ├── java-ci.yml         # workflow_call — Java check/JaCoCo
│   ├── docker-build.yml    # workflow_call — GHCR build/push + prune
│   └── helm-validate.yml   # workflow_call — helm lint/template
├── helm/
│   ├── gym-service/        # generic microservice chart (Istio + probes + SA + PDB)
│   │   └── examples/       # per-service values overlays (e.g. ms-gym-member)
│   └── gym-infra/          # local/dev data-plane sketch (Postgres/Kafka/Redis)
├── kong/                   # local DB-less Kong fixture (not K8s)
├── services/               # sample go-service / java-service for CI smoke
└── docs/local-k8s.md       # kind/k3d + Istio install
```

## Quality gates (service repos)

| Step | Go | Java |
|------|----|------|
| Lint | go vet + golangci-lint | Spotless (`check`) |
| Test | `go test -race` | Gradle `test` via `check` |
| Coverage | ≥ 95% (configurable) | JaCoCo ≥ 95% in service `build.gradle` |
| Image | GHCR on `develop` / `main` / `feature/*` / `hotfix/*` | same |
| Prune | keep ≤ 20 package versions | same |

## Use from another repo (e.g. ms-gym-member)

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [develop, main, 'feature/**', 'hotfix/**']
  pull_request:
    branches: [develop, main]

permissions:
  contents: read
  packages: write

jobs:
  java-ci:
    uses: pploc/gym-infra/.github/workflows/java-ci.yml@develop
    with:
      service_path: .
      java_version: '26'
      gradle_args: check
    secrets: inherit

  docker:
    needs: java-ci
    if: github.event_name == 'push' && (
      github.ref == 'refs/heads/develop' ||
      github.ref == 'refs/heads/main' ||
      startsWith(github.ref, 'refs/heads/feature/') ||
      startsWith(github.ref, 'refs/heads/hotfix/'))
    uses: pploc/gym-infra/.github/workflows/docker-build.yml@develop
    with:
      service_name: ms-gym-member
      context: .
      push: true
      max_tags: 20
    secrets: inherit
```

Images: `ghcr.io/<owner>/<service_name>:<sha>`, `:<branch>`, and `:latest` on `develop`/`main`.

## Helm (shared chart)

```bash
helm lint helm/gym-service
helm template t helm/gym-service --set istio.enabled=true
helm template member helm/gym-service -f helm/gym-service/examples/ms-gym-member-values.yaml
```

Defaults: Istio VirtualService + DestinationRule (ISTIO_MUTUAL) + PeerAuthentication STRICT, probes, non-root SA, PDB, NetworkPolicy. Classic nginx Ingress is off when Istio is on.

See [docs/local-k8s.md](docs/local-k8s.md) for kind/k3d + `istioctl`.

## Local sample tests

```bash
# Go
cd services/go-service && go test -race -coverprofile=coverage.out ./...

# Java
cd services/java-service && ./gradlew check
```

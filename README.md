# Gym Infra Repository

Shared DevOps infrastructure, Helm charts, CI/CD pipelines, and core Go/Java services for the Gym microservices architecture.

## Repository Structure

```
gym-infra/
├── .github/
│   └── workflows/
│       └── ci.yml             # GitHub Actions CI/CD pipeline
├── helm/
│   ├── gym-service/           # Generic microservice Helm chart
│   └── gym-infra/             # Local infrastructure dependencies Helm chart
└── services/
    ├── go-service/            # Go microservice with unit/integration tests (100% coverage)
    └── java-service/          # Java Spring Boot microservice with JUnit 5 & JaCoCo (100% coverage)
```

## Quality & Coverage Standards

- **Unit & Component/Integration Tests**: Run automatically in GitHub Actions.
- **Minimum Code Coverage Threshold**: `>= 95%` enforced for both Go (`go tool cover`) and Java (`JaCoCo`).
- **Container Registry**: Docker images built and pushed to GitHub Container Registry (`ghcr.io`).
- **Kubernetes Helm Actions**: Automated Helm linting, template rendering, and dry-run deployment checks.

## Local Execution

### Go Service Tests
```bash
cd services/go-service
go test -v -coverprofile=coverage.out ./...
go tool cover -func=coverage.out
```

### Java Service Tests
```bash
cd services/java-service
./gradlew check jacocoTestReport jacocoTestCoverageVerification
```

### Helm Chart Validation
```bash
helm lint helm/gym-service
helm lint helm/gym-infra
helm template test-service helm/gym-service
helm template test-infra helm/gym-infra
```

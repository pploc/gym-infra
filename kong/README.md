# Kong fixture environment

DB-less local Kong trust-boundary fixture for Phase 5 Part A.

## Quick start

```bash
docker compose -f docker-compose.yml up -d --build
cd tests && go test -v ./...
docker compose -f docker-compose.yml down
```

Proxy: `http://localhost:8000`  
Admin: `http://localhost:8001`

## Contents

| Path | Purpose |
|---|---|
| `kong.yml` | Declarative DB-less config (routes + plugin) |
| `plugins/gym-jwt-claims/` | RS256 validate, strip/inject trusted headers |
| `certs/` | Fixture RSA current/previous key pairs (test-only) |
| `mock-upstream/` | Go mock that records method/path/headers |
| `tests/gateway_test.go` | Gateway-local contract suite (Go) |
| `fixtures/kong-upstream-capture.json` | Sanitized upstream capture |

## Contract sources

- `gym-proto/contracts/v1/jwt-profile.json`
- `gym-proto/contracts/v1/auth/trusted-headers.json`
- `gym-proto/contracts/v1/routes.json`

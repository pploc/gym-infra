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
- `gym-proto/proto/http.yaml`

## Scope

This is fast Part A policy fixture. `mock-upstream` aliases `ms-gym-identifier` and `ms-gym-member` only so Kong uses production-shaped service DNS.

Member currently has no HTTP gateway/transcoder, so Kong exposes no Member external routes. Native `GetMembershipStatusByUserId` remains internal and has no Kong route. Add Member routes only with a real service-local HTTP gateway/transcoder.

Kong strips public `x-user-id`, `x-user-role`, `x-gym-id`, `x-membership-status`, and `x-trace-id`. It preserves W3C `traceparent` and `tracestate`.

## G5 transport topology

`g5-compose.yml` and `run-g5.sh` provide disposable Kong, Identifier, Member, PostgreSQL, Redis, Kafka, Schema Registry, and application mTLS wiring. `schema-seed` registers frozen event schemas in the empty disposable Schema Registry before either application starts. `generate-g5-certs.sh` creates a one-day CA plus Member server and Identifier client certificates; `g5-certs/` is removed on teardown and ignored by Git.

```bash
./run-g5.sh
```

After readiness, `run-g5.sh` runs `g5-business-check.sh`: Identifier registration and Kafka projection, email verification, gym-neutral login/refresh claims, Member mTLS gym selection, logout blacklist, multi-gym suspension, and outbox recovery. It reads the raw verification token through Confluent's official Protobuf consumer into a private file removed on exit; it never prints the token or URL. Gym, plan, and subscription rows are direct disposable Member DB fixtures because this topology has no Gym-management or Payment API.

Builds require `GITHUB_ACTOR` and `GITHUB_TOKEN`; the runner fails before Docker starts without them. Passing Identifier-led checks close G5 for the Identifier edge path. Member public HTTP remains a separate post-G5 surface.

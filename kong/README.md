# Kong fixture environment

DB-less local Kong trust-boundary fixture. `docker-compose.yml` and `run-g5.sh` remain historical Phase 5 inputs. G9 uses a separate locked fixture.

## G9 selected topology

```text
Browser HTTPS/JSON
  -> Kong JWT/CORS/exact routes
  -> mTLS generated Go grpc-gateway :8443
  -> mTLS Member and Plans gRPC :50051
```

Kong remains browser entry point and Identity HTTP upstream owner. It does not parse Protobuf or directly reach Member/Plans public gRPC methods. Kong 3.8 source-Protobuf `grpc-gateway` parsing failed on `buf/validate/validate.proto:535:9: field name expected`; do not restore that path.

Generated gateway accepts trusted identity/role metadata only from Kong SAN, then forwards vetted values to Member/Plans with `ms-gym-api-gateway` client identity. It registers only public generated routes, not workload-only RPCs.

## Locked G9 run

`g9-release-lock.json` is authoritative. `run-g9.sh` validates it and calls `materialize-g9.py`, which clones `gym-proto`, Identifier, Member, and Plans at exact detached commits into a temporary mode-`0700` workspace. Compose receives only materialized paths through `G9_PROTO_ROOT`, `G9_IDENTIFIER_ROOT`, `G9_MEMBER_ROOT`, and `G9_PLANS_ROOT`.

```bash
./run-g9.sh
```

Run only where `GITHUB_TOKEN` is already injected by protected CI or a secret manager. Protected CI maps environment secret `G9_READ_TOKEN` to it; this token needs read access to locked private repositories and package artifacts. Runner requires `PyYAML==6.0.3`. Do not put credentials in command history, Git configuration, Docker build args, Compose files, logs, evidence, or Git.

`run-g9.sh` removes temporary source, credentials, certificates, rendered configuration, containers, volumes, and fixture values on exit. It must work from clean `gym-infra` checkout with no sibling repositories present.

Final lock must include detached repository SHAs, v6.0.1 Java/Go artifact versions and checksums, canonical merged OpenAPI checksum, fake-payment contract identity, generated-gateway source identity/image digest, Kong image digest, route/template checksums, and redacted rendered-config checksum. Gateway runs as digest-pinned image after its source and image have been published; G9 must not rebuild mutable gateway source.

## G9 completion checks

- 27 exact public operations: Identity 12, Member 7, Plans 8;
- route and wrong-method negatives, JWT/trusted-header/CORS checks;
- Kong-to-gateway and gateway-to-service mTLS/SAN checks;
- no Kong direct Member/Plans `50051` access;
- workload-only RPC isolation;
- Plans `8080 /api/**` returns `404`; Actuator stays healthy;
- safe deterministic `500`/`503` envelope;
- Helm and port-specific NetworkPolicy checks;
- TypeScript generation from released canonical OpenAPI and `tsc --noEmit`;
- schema-controlled sanitized evidence only.

Raw logs remain private CI diagnostics. Never commit keys, JWTs, tokens, Authorization values, PII, fixture IDs, raw Protobuf payloads, or raw stack/transport details.

## Historical G5 fixture

```bash
docker compose -f docker-compose.yml up -d --build
cd tests && go test -v ./...
docker compose -f docker-compose.yml down
```

Proxy: `http://localhost:8000`

Admin: `http://localhost:8001`

`g5-compose.yml` and `run-g5.sh` use disposable Kong, Identifier, Member, PostgreSQL, Redis, Kafka, Schema Registry, and Member mTLS wiring. `schema-seed` registers frozen event schemas before applications start. `generate-g5-certs.sh` creates ignored short-lived certificates removed on teardown.

G5 is historical: it does not define G9 public Member/Plans routes, source materialization, or final release proof.

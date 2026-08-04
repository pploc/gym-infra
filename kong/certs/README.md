# Fixture signing keys (test-only)

| File | Use |
|---|---|
| `fixture_rsa.key` / `fixture_rsa.pub` | current kid |
| `fixture_rsa_prev.key` / `fixture_rsa_prev.pub` | previous kid (rotation overlap) |

Allowed by `jwt-profile.json` testing contract.  
Never use these keys in production. Production private keys come from secret-manager and are never committed.

# StrongBox — Distributed Secrets Manager

StrongBox is a Bash-based distributed secrets manager built for the HNG DevOps Stage 8 task. It runs as a three-node cluster behind Nginx and provides sealed boot, K-of-N unseal, envelope encryption, opaque bearer-token authentication, path-based authorization policies, versioned secrets, leases, dynamic PostgreSQL credentials, hand-rolled leader election, and tamper-evident audit logging.

StrongBox is not a wrapper around HashiCorp Vault, AWS Secrets Manager, GCP Secret Manager, or any existing secrets engine. The platform logic is implemented in Bash. Python is used only for Shamir finite-field arithmetic in `lib/shamir.py`. Cryptographic operations use standard command-line primitives such as `openssl` and `argon2`, rather than custom AES, HMAC, or password-hashing code.

## Deployment details

The StrongBox deployment consists of three StrongBox nodes, one PostgreSQL target database, and one Nginx reverse proxy. Nginx exposes the public API over HTTP/HTTPS and forwards traffic to the StrongBox cluster. The cluster elects one leader at a time. The leader accepts writes, replicates write operations to peers, and only returns success when a quorum acknowledges replication. Followers reject writes with a leader hint and expose health information for cluster inspection.

```text
Public URL: https://<strongbox-domain>
GitHub repo: https://github.com/<user>/<repo>
Cluster size: 3 StrongBox nodes
Reverse proxy: Nginx + TLS
Target database: PostgreSQL
Runtime mode: Docker Compose on a Linux VPS
```

The public URL and repository URL are the values submitted to the grader. The root token created during initialization is scoped for grader access according to the submission instructions.

## What StrongBox provides

StrongBox stores application secrets outside source code, Docker Compose files, `.env` files, and internal documentation. Applications request secrets from StrongBox at runtime using bearer tokens. StrongBox authenticates the token, checks policies, verifies the vault is unsealed, decrypts the requested secret, attaches a lease, and records the action in the audit log.

Every static secret write creates a new version. Reading a secret without a version returns the latest version. Reading with `?version=N` returns the requested historical version. Each version is encrypted independently using envelope encryption: StrongBox generates a random data encryption key for the secret value, encrypts the value with AES-256-GCM, and wraps the data encryption key with the in-memory key-encryption key.

Dynamic PostgreSQL credentials are generated on demand. A read from `dynamic-postgres/{role}` creates a fresh PostgreSQL role, grants the configured permissions, returns a username and password to the caller, and stores a lease. When the lease expires, the lease reaper revokes privileges and drops the PostgreSQL role. If PostgreSQL is unavailable during cleanup, the lease enters `revocation_pending` and the reaper retries with exponential backoff until cleanup succeeds.

## Architecture

The cluster contains three StrongBox nodes: `strongbox1`, `strongbox2`, and `strongbox3`. Each node runs the same code with a different `NODE_ID`. Nodes communicate over internal HTTP endpoints for leader election, heartbeats, votes, and replication. Public clients do not call the internal endpoints directly.

<img width="1536" height="946" alt="ChatGPT Image Jun 1, 2026, 05_29_19 PM" src="https://github.com/user-attachments/assets/bef15cb0-5073-4fa6-bd3b-74d1f358c8fc" />


Nginx handles TLS termination and public routing. StrongBox handles security logic: sealed state, unseal, auth, policy checks, encryption, leases, dynamic credentials, consensus, and audit logging. PostgreSQL is the target system used by the dynamic secrets engine.

The detailed architecture document is available at `docs/architecture.md`. The architecture diagram is available at `docs/architecture.png`.

## Repository structure

```text
bin/
  strongbox             Main server entrypoint
  strongbox-verify      Audit log verifier

lib/
  config.sh             Configuration loader and environment override handling
  crypto.sh             Envelope encryption helpers
  auth.sh               Login, tokens, token revocation, and policy checks
  lease.sh              Lease creation, renewal, revocation, expiry, and reaper logic
  dynamic.sh            Dynamic PostgreSQL credential engine
  consensus.sh          Leader election, terms, votes, heartbeats, and replication
  audit.sh              Tamper-evident HMAC audit chain
  shamir.py             Shamir K-of-N reconstruction over GF(2^8)
  storage.sh            In-memory storage interface
  http.sh               HTTP routing and API handlers

test/integration/       Integration tests for the three-node cluster
nginx/nginx.conf        Nginx reverse-proxy configuration
compose.yaml            Three-node StrongBox, PostgreSQL, and Nginx runtime
config.yaml             Ports, TTLs, cluster peers, storage paths, and database settings
docs/architecture.md    Architecture explanation
docs/architecture.png   Architecture diagram
docs/threat-model.md    Threat model
screenshots/            Required proof screenshots
README.md               Operator and grader guide
```

The `lib/storage.sh` file provides the storage interface used by the rest of the system. Other modules call storage functions such as `storage_put_secret_version`, `storage_get_secret_version`, `storage_put_token`, `storage_revoke_token`, and `storage_put_lease` instead of writing directly to the runtime directory. This keeps the backend replaceable and keeps platform logic separate from persistence details.

## Configuration

StrongBox reads settings from `config.yaml`. Environment variables override config file values so the same code runs locally, in Docker Compose, on a staging VPS, and in the final grader deployment.

```yaml
server:
  bind_host: "0.0.0.0"
  port: 8080
  public_url: "https://<strongbox-domain>"

cluster:
  node_id: "node1"
  election_timeout_ms_min: 800
  election_timeout_ms_max: 1500
  heartbeat_interval_ms: 250
  peers:
    - id: "node1"
      url: "http://strongbox1:8080"
    - id: "node2"
      url: "http://strongbox2:8080"
    - id: "node3"
      url: "http://strongbox3:8080"

storage:
  runtime_dir: "/run/strongbox"
  audit_log: "/var/log/strongbox/audit.log"
  sealed_metadata_dir: "/var/lib/strongbox"

seal:
  shares: 3
  threshold: 2

crypto:
  dek_bytes: 32
  nonce_bytes: 12
  token_bytes: 32

leases:
  default_ttl_seconds: 60
  max_ttl_seconds: 300
  reaper_interval_seconds: 5
  revocation_initial_backoff_seconds: 5
  revocation_max_backoff_seconds: 60

postgres:
  host: "postgres"
  port: 5432
  database: "appdb"
  admin_user: "postgres"
  admin_password_env: "POSTGRES_ADMIN_PASSWORD"
```

For local macOS development, use `/tmp/strongbox` because `/run` is a Linux runtime path and may be read-only on macOS.

```bash
STRONGBOX_RUNTIME_DIR=/tmp/strongbox ./bin/strongbox
```

For Docker Compose and Linux VPS deployment, `/run/strongbox` is used as the runtime directory. Each Compose service sets a different `NODE_ID`, so all three nodes run the same image while maintaining separate cluster identities.

## Fresh VPS setup

Start with a Linux VPS that has at least 4 vCPU, 4 GB RAM, and 40 GB disk. Install Docker, Docker Compose, Git, Nginx dependencies, and Certbot. Clone the public repository, configure the domain DNS record to point to the VPS, and start the Compose stack.

```bash
git clone https://github.com/<user>/<repo>.git strongbox
cd strongbox
cp config.yaml config.production.yaml
```

Set production-specific values in `config.production.yaml`, including the public URL, PostgreSQL settings, storage paths, lease TTLs, and cluster peer URLs. Export the config path and any sensitive environment values before starting the cluster.

```bash
export STRONGBOX_CONFIG=/app/config.production.yaml
export POSTGRES_ADMIN_PASSWORD='<postgres-admin-password>'
docker compose up -d --build
```

Check that all services are running.

```bash
docker compose ps
```

Check cluster health through the public URL.

```bash
curl -s https://<strongbox-domain>/v1/sys/health | jq
```

A freshly started cluster reports sealed state. Secret operations return `503` while the vault is sealed.

## Initialization and unseal

Initialize StrongBox once. Initialization creates the master key material, wraps the in-memory key-encryption key, creates Shamir shares, creates the root policy, creates the root token, and prepares audit HMAC material.

```bash
curl -s -X POST https://<strongbox-domain>/v1/sys/init | jq
```

The response contains the unseal shares and root token.

```json
{
  "shares": ["share-1", "share-2", "share-3"],
  "root_token": "root-token-value"
}
```

Submit one share per request. With a `2-of-3` threshold, the first valid share records progress and the second valid share reconstructs the master key, unwraps the key-encryption key, clears submitted share material, and transitions the cluster to unsealed state.

```bash
curl -s -X POST https://<strongbox-domain>/v1/sys/unseal \
  -H 'Content-Type: application/json' \
  -d '{"share":"share-1"}' | jq

curl -s -X POST https://<strongbox-domain>/v1/sys/unseal \
  -H 'Content-Type: application/json' \
  -d '{"share":"share-2"}' | jq
```

Check health again.

```bash
curl -s https://<strongbox-domain>/v1/sys/health | jq
```

The cluster reports `sealed: false`, a current `term`, the local `node_id`, and leader information.

## Authentication and policies

StrongBox uses opaque bearer tokens. Tokens are random values generated from a cryptographically secure source. Every authenticated request checks server-side token state, so revocation takes effect immediately on the next request.

Create a policy that allows read access to `secret/app/*`.

```bash
ROOT_TOKEN='<root-token-value>'

curl -s -X PUT https://<strongbox-domain>/v1/policies/app-read \
  -H "Authorization: Bearer $ROOT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "rules": [
      {
        "path": "secret/app/*",
        "capabilities": ["read"]
      }
    ]
  }' | jq
```

Create or log in as a user that receives the `app-read` policy.

```bash
curl -s -X POST https://<strongbox-domain>/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"app","password":"<password>"}' | jq
```

Use the returned token for reads. A token with `read` on `secret/app/*` can read `secret/app/db`, cannot write `secret/app/db`, and cannot read `secret/other/x`.

Revoke a token synchronously.

```bash
curl -s -X POST https://<strongbox-domain>/v1/auth/revoke \
  -H "Authorization: Bearer $ROOT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"token":"<token-to-revoke>"}' -i
```

The revoked token returns `401 Unauthorized` on the next request.

## Static secrets and versioning

Write a secret to `secret/app/db`.

```bash
curl -s -X PUT https://<strongbox-domain>/v1/secrets/app/db \
  -H "Authorization: Bearer $ROOT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "data": {
      "username": "app",
      "password": "first-password"
    }
  }' | jq
```

The response returns the created version.

```json
{
  "version": 1
}
```

Write the same path again to create a new version.

```bash
curl -s -X PUT https://<strongbox-domain>/v1/secrets/app/db \
  -H "Authorization: Bearer $ROOT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "data": {
      "username": "app",
      "password": "second-password"
    }
  }' | jq
```

Read the latest version.

```bash
curl -s https://<strongbox-domain>/v1/secrets/app/db \
  -H "Authorization: Bearer $ROOT_TOKEN" | jq
```

Read the first version explicitly.

```bash
curl -s 'https://<strongbox-domain>/v1/secrets/app/db?version=1' \
  -H "Authorization: Bearer $ROOT_TOKEN" | jq
```

Every read response includes the secret data, version number, and lease information.

## Dynamic PostgreSQL credentials

A read from `dynamic-postgres/readonly` creates a fresh PostgreSQL role on the configured target database, grants readonly permissions, returns the generated username and password, and stores a lease.

```bash
curl -s https://<strongbox-domain>/v1/dynamic-postgres/readonly \
  -H "Authorization: Bearer $ROOT_TOKEN" | jq
```

Example response:

```json
{
  "username": "sb_readonly_7fa91c",
  "password": "generated-password",
  "lease": {
    "id": "lease_abc123",
    "ttl": 60
  }
}
```

Confirm the role exists in PostgreSQL.

```bash
docker compose exec postgres psql -U postgres -d appdb \
  -c "SELECT rolname FROM pg_roles WHERE rolname LIKE 'sb_readonly_%';"
```

When the lease expires, the reaper revokes privileges and drops the role. If PostgreSQL is down at expiry time, StrongBox marks the lease `revocation_pending`, records the failed cleanup in the audit log, and retries automatically with exponential backoff. After PostgreSQL becomes reachable again, the reaper completes the cleanup without manual intervention.

## Lease operations

Renew an active lease before it expires.

```bash
curl -s -X POST https://<strongbox-domain>/v1/leases/<lease-id>/renew \
  -H "Authorization: Bearer $ROOT_TOKEN" | jq
```

Revoke a lease manually.

```bash
curl -s -X POST https://<strongbox-domain>/v1/leases/<lease-id>/revoke \
  -H "Authorization: Bearer $ROOT_TOKEN" -i
```

Static secret leases control how long a read grant remains renewable. Dynamic PostgreSQL leases control the lifecycle of real database credentials. Expired leases cannot be renewed. Revoked leases are terminal. Failed dynamic cleanup uses the `revocation_pending` state until the external database-side revocation succeeds.

## Leader election and write safety

StrongBox uses a hand-rolled leader election protocol with terms, votes, election timeouts, and heartbeats. Each node begins as a follower. When a follower stops receiving leader heartbeats for longer than the election timeout, it becomes a candidate, increments its term, votes for itself, and requests votes from peers. A node grants at most one vote per term. A candidate that receives a majority becomes leader and starts sending heartbeats.

In a three-node cluster, majority is two nodes. This majority rule prevents split-brain. During a `2-1` partition, the two-node side can elect a leader and continue accepting writes. The isolated one-node side cannot reach majority and refuses writes. Followers reject writes with a leader hint, so clients can retry against the leader.

Writes are acknowledged only after the leader replicates the operation to a majority. This protects against acknowledged write loss. If the leader dies before majority commit, the write fails cleanly or remains unacknowledged. If the leader acknowledges the write, the committed entry exists on a majority and remains available after a new leader is elected.

## Audit log and verification

StrongBox records security-relevant events in an append-only audit log. Audit events include auth activity, token revocation, secret reads, secret writes, secret deletes, policy updates, lease events, dynamic PostgreSQL credential creation, PostgreSQL revocation failures, PostgreSQL cleanup success, and consensus events.

Each audit entry contains a hash of the previous entry and an HMAC over the current entry content. This creates a tamper-evident chain. Changing a single byte in any entry breaks verification from that point forward.

Verify the audit log with:

```bash
docker compose exec strongbox-1 /app/bin/strongbox-verify /data/audit/audit.log
```

A valid log exits with status `0`. A modified log exits non-zero and prints the corrupted entry index.

## Seal behavior and memory hygiene

StrongBox boots sealed. While sealed, only health, initialization, and unseal endpoints respond. Secret reads, secret writes, login, leases, policy changes, dynamic PostgreSQL credentials, and audit queries are blocked with `503 Service Unavailable` until the vault is unsealed.

During unseal, StrongBox accepts one Shamir share per request. Once the configured threshold is reached, `lib/shamir.py` reconstructs the master key, StrongBox unwraps the key-encryption key, and the vault transitions to unsealed state. Submitted shares, reconstructed master-key material, and Shamir intermediate values are cleared after use. Bash does not provide the same deterministic memory-zeroization guarantees as a lower-level language, so StrongBox reduces exposure by keeping key material out of command-line arguments, avoiding environment variables for sensitive values, using runtime memory-backed storage, clearing variables after use, and limiting the lifetime of subprocesses that touch sensitive material.

Manual seal purges the active key-encryption key and returns the vault to sealed state.

```bash
curl -s -X POST https://<strongbox-domain>/v1/sys/seal \
  -H "Authorization: Bearer $ROOT_TOKEN" -i
```

## Required grading scenarios

The cluster boots sealed and rejects secret operations until unsealed. K-of-N unseal transitions the cluster to unsealed state. Secret writes create versions and historical versions remain retrievable. Token policies enforce path and capability restrictions. Revoked tokens fail immediately on the next request. Dynamic PostgreSQL reads create real database roles and working credentials. Expired dynamic leases clean up PostgreSQL roles, including retry after database downtime. Killing the leader mid-write produces either a clean failure or a durable committed write. A two-node majority partition elects a leader and continues writes while the minority refuses writes. Audit verification detects single-byte tampering and names the corrupted entry index.

## Screenshots

The `screenshots/` directory contains proof images for the grading scenarios.

```text
screenshots/cluster-sealed.png
screenshots/unseal-flow.png
screenshots/dynamic-postgres.png
screenshots/leader-killed.png
screenshots/partition.png
screenshots/audit-tampered.png
screenshots/memory-clean.png
```

Each screenshot is linked from the final submission README and captures the command output or UI evidence for the corresponding scenario.

## API reference

```http
POST   /v1/sys/init
POST   /v1/sys/unseal
POST   /v1/sys/seal
GET    /v1/sys/health

PUT    /v1/secrets/{path}
GET    /v1/secrets/{path}?version=N
DELETE /v1/secrets/{path}

GET    /v1/dynamic-postgres/{role}

POST   /v1/auth/login
POST   /v1/auth/revoke
GET    /v1/auth/self

PUT    /v1/policies/{name}
GET    /v1/policies/{name}

POST   /v1/leases/{id}/renew
POST   /v1/leases/{id}/revoke

GET    /v1/audit?token=<id>
```

All non-system write operations require `Authorization: Bearer <token>`. JSON is used for request and response bodies. `204 No Content` is used for successful operations that do not return a response body.

## Development commands

Run the cluster locally with Docker Compose.

```bash
docker compose up -d --build
```

View logs.

```bash
docker compose logs -f
```

Check containers.

```bash
docker compose ps
```

Stop the cluster.

```bash
docker compose down
```

Run local single-process development on macOS with a writable runtime directory.

```bash
STRONGBOX_RUNTIME_DIR=/tmp/strongbox ./bin/strongbox
```

Inspect runtime state during local development.

```bash
find /tmp/strongbox -maxdepth 2 | sort
```

## Security boundaries

StrongBox protects against plaintext secrets in repositories, plaintext secrets in Compose files, long-lived shared database credentials, undetected audit log tampering, stale token access after revocation, and unsafe minority-partition writes. StrongBox does not protect against a fully compromised host while the vault is unsealed, a malicious kernel, compromised PostgreSQL admin credentials, denial-of-service attacks, or bugs in the underlying cryptographic and database tools.

The full threat model is documented in `docs/threat-model.md`.

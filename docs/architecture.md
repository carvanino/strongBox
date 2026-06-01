# StrongBox Architecture

> Status: design target for the final implementation.

StrongBox is a 3-node distributed secrets manager. It exposes one HTTP API, stores secret state behind a storage interface, encrypts each secret version using envelope encryption, enforces token and policy authorization, issues leases, creates dynamic PostgreSQL credentials, elects a leader, and writes tamper-evident audit logs.

---

## 1. High-level system view

```text
Client/Application
      |
      | HTTPS + Bearer token
      v
Nginx reverse proxy
      |
      | HTTP inside Docker network
      v
StrongBox cluster
  - strongbox1
  - strongbox2
  - strongbox3
      |
      +--> PostgreSQL target DB
      |
      +--> audit log files
      |
      +--> runtime state through storage interface
```

The public entrypoint is Nginx. Nginx terminates TLS and forwards traffic to the StrongBox nodes. Each StrongBox node runs the same code but has a unique node ID.

---

## 2. Components

### 2.1 Nginx

Nginx is the public-facing reverse proxy.

Responsibilities:

```text
terminate TLS
listen on ports 80/443
forward API requests to StrongBox nodes
preserve client forwarding headers
```

Nginx does not perform authorization and does not handle secrets directly.

---

### 2.2 StrongBox node

Each node runs `bin/strongbox`.

Startup flow:

```text
load config
initialize runtime storage
initialize consensus state
start background loops
start HTTP server
```

Main modules:

| Module | Responsibility |
|---|---|
| `lib/config.sh` | Load `config.yaml` and environment overrides. |
| `lib/http.sh` | Parse HTTP requests and route endpoints. |
| `lib/storage.sh` | Provide storage interface. |
| `lib/crypto.sh` | Envelope encryption and key wrapping. |
| `lib/auth.sh` | Login, token validation, policy checks. |
| `lib/lease.sh` | Lease creation, renewal, expiry, revocation. |
| `lib/dynamic.sh` | Dynamic PostgreSQL role creation and cleanup. |
| `lib/consensus.sh` | Leader election, heartbeats, write replication. |
| `lib/audit.sh` | Append tamper-evident audit entries. |
| `lib/shamir.py` | Shamir K-of-N reconstruction math. |

---

### 2.3 PostgreSQL

PostgreSQL is the target system for the dynamic secrets engine.

When a client reads:

```text
/v1/dynamic-postgres/readonly
```

StrongBox connects to PostgreSQL as an admin user and creates a fresh temporary role.

The returned username/password are leased. When the lease expires, the reaper revokes privileges and drops the role.

---

### 2.4 Audit log

The audit log is append-only JSON lines.

Each entry contains:

```text
index
timestamp
node ID
term
token ID
operation
path
status
previous hash
current hash
```

The current hash uses HMAC-SHA256 over the previous hash plus canonicalized event content. This creates a tamper-evident chain.

`bin/strongbox-verify` replays the chain from the beginning and fails on the first mismatch.

---

## 3. Request lifecycle

### 3.1 Static secret read

```text
1. Client sends GET /v1/secrets/app/db with Authorization header.
2. http.sh routes the request.
3. sealed guard checks whether vault is unsealed.
4. auth.sh validates bearer token server-side.
5. auth.sh checks policy for read on secret/app/db.
6. storage.sh loads requested secret version.
7. crypto.sh unwraps DEK using in-memory KEK.
8. crypto.sh decrypts ciphertext using DEK.
9. lease.sh creates a read lease.
10. audit.sh appends secret.read event.
11. http.sh returns JSON response.
```

Response shape:

```json
{
  "data": {
    "username": "app",
    "password": "secret"
  },
  "version": 1,
  "lease": {
    "id": "lease_...",
    "ttl": 60
  }
}
```

---

### 3.2 Static secret write

```text
1. Client sends PUT /v1/secrets/app/db.
2. Node checks vault is unsealed.
3. Node validates token.
4. Node checks write capability.
5. Node checks it is leader.
6. Leader generates version number.
7. crypto.sh generates random DEK.
8. crypto.sh encrypts secret data with AES-256-GCM.
9. crypto.sh wraps DEK with KEK.
10. consensus.sh replicates write to majority.
11. storage.sh commits secret version.
12. audit.sh appends secret.write event.
13. http.sh returns 201 {version}.
```

The write is acknowledged only after majority replication.

---

### 3.3 Dynamic PostgreSQL credential read

```text
1. Client sends GET /v1/dynamic-postgres/readonly.
2. Node validates sealed state, token, and policy.
3. Node checks leader requirement for dynamic credential creation.
4. dynamic.sh generates random username and password.
5. dynamic.sh connects to PostgreSQL as admin.
6. dynamic.sh creates role and grants permissions.
7. lease.sh creates a dynamic-postgres lease.
8. audit.sh records dynamic.postgres.create and lease.create.
9. Client receives username, password, and lease.
10. lease reaper later revokes and drops the role.
```

---

## 4. Seal and unseal architecture

StrongBox boots sealed.

Allowed while sealed:

```text
GET  /v1/sys/health
POST /v1/sys/init
POST /v1/sys/unseal
```

Blocked while sealed:

```text
secret operations
auth login
policy writes
dynamic PostgreSQL reads
lease renew/revoke
audit reads
```

Unseal data flow:

```text
Shamir shares
    |
    v
lib/shamir.py reconstructs master key
    |
    v
master key unwraps KEK
    |
    v
KEK loaded into runtime memory
    |
    v
vault becomes unsealed
```

The KEK is required to unwrap per-secret DEKs. Without the KEK, stored ciphertext cannot be decrypted.

When `/v1/sys/seal` is called, the node purges KEK runtime state and returns to sealed mode.

---

## 5. Envelope encryption

StrongBox uses envelope encryption to avoid encrypting all secrets directly with one long-lived key.

```text
Secret plaintext
    |
    | encrypted by random DEK
    v
Secret ciphertext

DEK
    |
    | wrapped by KEK
    v
Wrapped DEK
```

Stored secret version record:

```json
{
  "path": "secret/app/db",
  "version": 1,
  "created_at": "timestamp",
  "created_by": "token_id",
  "ciphertext": "base64",
  "nonce": "base64",
  "tag": "base64",
  "wrapped_dek": "base64",
  "dek_wrap_nonce": "base64"
}
```

Key hierarchy:

```text
Shamir shares reconstruct master key
master key unwraps KEK
KEK unwraps per-secret DEK
DEK decrypts one secret version
```

---

## 6. Storage architecture

The storage layer is accessed only through `lib/storage.sh`.

Initial backend:

```text
tmpfs-backed runtime directory
```

Example runtime tree:

```text
/run/strongbox/
├── secrets/
├── tokens/
├── policies/
├── leases/
├── cluster/
└── unseal/
```

On macOS local development, use:

```bash
STRONGBOX_RUNTIME_DIR=/tmp/strongbox ./bin/strongbox
```

Why a storage interface matters:

```text
crypto.sh does not know where secret files live
auth.sh does not know how token records are persisted
lease.sh does not know whether leases are files or future BoltDB records
consensus.sh does not directly own low-level storage layout
```

This makes it possible to replace the backend later.

---

## 7. Authentication and policy architecture

Authentication answers:

```text
Who are you?
```

Authorization answers:

```text
What are you allowed to do?
```

StrongBox uses opaque bearer tokens.

Token rules:

```text
random bytes from CSPRNG
at least 32 bytes
not JWTs
raw token returned only once
server stores token hash/state
revocation checked on every request
```

Policy rules use path prefixes and capabilities:

```json
{
  "rules": [
    {
      "path": "secret/app/*",
      "capabilities": ["read"]
    }
  ]
}
```

Capabilities:

```text
read
write
delete
```

Example behavior:

```text
read secret/app/db       -> allowed
write secret/app/db      -> denied
read secret/other/x      -> denied
```

---

## 8. Lease architecture

Every secret read returns a lease. Leases limit how long a caller should rely on returned data.

Required states:

```text
active
expired
revoked
revocation_pending
```

Lease lifecycle:

```text
active
  -> renewed
  -> expired
  -> revoked

active
  -> expired
  -> revocation_pending
  -> revoked
```

For static secrets, expiry mainly affects renewability.

For dynamic PostgreSQL credentials, expiry triggers external cleanup.

---

## 9. Dynamic PostgreSQL architecture

Dynamic credentials are not stored passwords. They are generated on demand.

Creation:

```sql
CREATE ROLE sb_readonly_xxxxx LOGIN PASSWORD 'generated';
GRANT CONNECT ON DATABASE appdb TO sb_readonly_xxxxx;
GRANT USAGE ON SCHEMA public TO sb_readonly_xxxxx;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO sb_readonly_xxxxx;
```

Revocation:

```sql
REVOKE ALL PRIVILEGES ON DATABASE appdb FROM sb_readonly_xxxxx;
DROP ROLE sb_readonly_xxxxx;
```

If PostgreSQL is down during revocation:

```text
lease state becomes revocation_pending
last error is recorded
next retry timestamp is calculated
reaper retries with exponential backoff
successful cleanup changes state to revoked
```

---

## 10. Consensus architecture

StrongBox uses a hand-rolled leader election protocol.

Node roles:

```text
follower
candidate
leader
```

Persistent/runtime election fields:

```text
current_term
voted_for
role
leader_id
last_heartbeat_at
```

Rules:

```text
all nodes start as followers
leader sends heartbeats
followers start election after heartbeat timeout
candidate increments term
candidate votes for itself
candidate requests votes from peers
majority vote makes candidate leader
leader accepts writes
followers reject writes with leader hint
node without majority refuses writes
```

For 3 nodes:

```text
majority = 2
```

This gives the required partition behavior:

```text
2-node side can elect/keep leader and write
1-node side refuses writes
```

---

## 11. Write safety

Write acknowledgment rule:

```text
Do not return success until the write is replicated to a majority.
```

Reason:

If the leader acknowledges a write before replication, then dies, the new leader may not have the write.

That would violate the requirement:

```text
never both acknowledged and lost
```

Write flow:

```text
client -> leader
leader builds write record
leader replicates to peers
majority confirms
leader commits locally
leader returns success
```

---

## 12. Read consistency

The simplest safe model is:

```text
leader serves all writes
followers may serve health and read-only metadata
secret reads may be redirected to leader unless follower-read staleness is explicitly documented
```

If follower reads are enabled, the README must document:

```text
Follower reads can be stale until the follower has received the latest committed write.
```

For grading simplicity, the safest starting implementation is to route secret reads to the leader.

---

## 13. Deployment architecture

Docker Compose services:

```text
strongbox1
strongbox2
strongbox3
postgres
nginx
```

Network:

```text
public internet -> Nginx -> internal Docker network -> StrongBox nodes/PostgreSQL
```

Storage volumes:

```text
node runtime state
node sealed metadata
node audit logs
PostgreSQL data
```

Nginx handles TLS. StrongBox receives internal HTTP traffic.

---

## 14. Architecture diagram

See `docs/architecture.png`.

The diagram shows:

```text
client/API flow
Nginx reverse proxy
3-node StrongBox cluster
internal module boundaries
PostgreSQL dynamic credential flow
audit verification flow
seal/unseal key flow
```

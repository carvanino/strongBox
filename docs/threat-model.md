# StrongBox Threat Model

> Status: design target for the final implementation. This document must be updated if implementation decisions change.

StrongBox is a secrets manager. Its purpose is to reduce plaintext secret exposure, enforce access control, issue temporary credentials, and provide audit evidence. It is not a complete defense against a fully compromised host or malicious kernel.

---

## 1. Security goals

StrongBox is designed to provide:

```text
confidentiality of stored secrets
authenticated access to secrets
authorization through path policies
immediate token revocation
leased access to returned secrets
automatic cleanup of dynamic PostgreSQL credentials
tamper-evident audit history
safe behavior during node failure and network partition
sealed boot until operator unseal
```

---

## 2. Assets

The assets StrongBox protects are:

| Asset | Why it matters |
|---|---|
| Secret plaintext | Database passwords, API keys, app secrets. |
| KEK | Key Encryption Key used to unwrap DEKs. |
| DEKs | Per-secret data encryption keys. |
| Master key | Reconstructed from Shamir shares to unwrap KEK. |
| Shamir shares | Operator-held unseal material. |
| Bearer tokens | API credentials for callers. |
| Password hashes | Stored login password verifiers. |
| Dynamic PostgreSQL credentials | Temporary DB users/passwords. |
| Audit HMAC key | Protects audit log integrity. |
| Audit logs | Evidence of system activity. |
| Cluster state | Leader, term, vote, and commit state. |
| Policy records | Authorization rules. |
| Lease records | Credential lifecycle state. |

---

## 3. Trust boundaries

### 3.1 Public internet to Nginx

External clients communicate with Nginx over HTTPS.

Risk:

```text
network interception
spoofed clients
replay attempts
malformed requests
```

Controls:

```text
TLS termination
Authorization header required for protected endpoints
JSON input validation
audit logging
```

---

### 3.2 Nginx to StrongBox nodes

Nginx forwards requests to nodes over the internal Docker network.

Risk:

```text
wrong node receives write
follower receives leader-only operation
```

Controls:

```text
leader check in StrongBox
followers reject writes with leader hint
node identity and term included in health/consensus state
```

---

### 3.3 StrongBox to PostgreSQL

StrongBox connects as a privileged Postgres admin to create and remove temporary roles.

Risk:

```text
admin credential compromise
database unreachable during cleanup
overly broad grants
failed DROP ROLE leaving credential alive
```

Controls:

```text
admin password comes from environment, not committed config
least-privilege role templates
lease reaper
revocation_pending state
exponential backoff retries
audit events for creation and revocation
```

---

### 3.4 StrongBox runtime memory

While unsealed, StrongBox must hold enough key material to decrypt secrets.

Risk:

```text
memory dump during unsealed operation
Bash variable copies
subprocess argument leakage
environment variable leakage
```

Controls:

```text
vault starts sealed
KEK only available after unseal
shares/master key cleared after unseal
avoid passing secrets in command-line arguments
avoid storing key material in environment variables
use tmpfs for runtime state
unset sensitive variables
short-lived subprocesses where practical
memory-clean verification screenshot
```

Limitation:

```text
Bash does not provide strong guaranteed memory zeroization.
```

---

### 3.5 StrongBox audit log

Audit logs are written to disk.

Risk:

```text
attacker modifies or deletes audit entries
operator edits log after incident
partial writes
```

Controls:

```text
HMAC chain
previous hash included in each entry
strongbox-verify recomputes chain from genesis
verification fails with corrupted entry index
audit HMAC key stored outside source control with restrictive file permissions
```

Limitation:

```text
If an attacker deletes the entire log and also destroys all backups, StrongBox can detect absence operationally but cannot reconstruct deleted evidence by itself.
```

---

## 4. In-scope threats and controls

### 4.1 Plaintext secrets committed to repos

Threat:

```text
Developers store secrets in .env, compose files, GitHub, or wiki pages.
```

Control:

```text
StrongBox stores encrypted secret records and exposes secrets only after authz checks.
```

Residual risk:

```text
A client may still log or mishandle returned secrets.
```

---

### 4.2 Stolen token

Threat:

```text
An attacker obtains a bearer token.
```

Controls:

```text
tokens are opaque and high entropy
server stores token state
policy scopes limit token power
revocation is synchronous
revoked token fails on next request
audit records token activity
```

Residual risk:

```text
A stolen valid token can be used until revoked or expired.
```

---

### 4.3 Revoked token reuse

Threat:

```text
A token is revoked but continues to work because of cache lag.
```

Control:

```text
Every protected request checks server-side token state.
No auth cache TTL is allowed for token validity.
```

Expected behavior:

```text
revoked token -> next request returns 401
```

---

### 4.4 Unauthorized path access

Threat:

```text
A token for secret/app/* tries to read secret/other/x.
```

Control:

```text
path-prefix policy check with capabilities
```

Expected behavior:

```text
valid token + wrong path -> 403
```

---

### 4.5 Secret overwrite mistake

Threat:

```text
A user overwrites a secret with the wrong value.
```

Control:

```text
every write creates a new version
older versions are retrievable with ?version=N
```

Residual risk:

```text
If deletion is implemented as destructive deletion, recovery may require backups or retained versions depending on final delete semantics.
```

---

### 4.6 Database credential leakage

Threat:

```text
A dynamic Postgres credential leaks.
```

Controls:

```text
credential has short lease TTL
credential is unique per read
lease reaper revokes and drops role
role grants are limited by template
```

Residual risk:

```text
The credential can be used until expiry/revocation.
```

---

### 4.7 PostgreSQL unavailable during revocation

Threat:

```text
Lease expires, but Postgres is down, so the role cannot be dropped.
```

Control:

```text
lease becomes revocation_pending
last error is recorded
reaper retries with exponential backoff
eventual success moves lease to revoked
```

Expected behavior:

```text
cleanup succeeds automatically after Postgres returns
```

---

### 4.8 Audit log tampering

Threat:

```text
Attacker changes a log entry after an incident.
```

Controls:

```text
each entry includes previous hash
entry hash is HMAC-SHA256
verifier recomputes from genesis
mismatch identifies corrupted entry index
```

Residual risk:

```text
If attacker gets audit HMAC key and can rewrite every entry, tamper resistance is weakened.
```

---

### 4.9 Leader failure

Threat:

```text
Leader dies during a write.
```

Controls:

```text
write acknowledged only after majority replication
new leader must be elected by majority
uncommitted write fails cleanly
```

Expected behavior:

```text
write either fails or completes durably
never acknowledged and lost
```

---

### 4.10 Network partition

Threat:

```text
Cluster splits 2-1.
```

Controls:

```text
majority required for leadership and writes
minority partition refuses writes
```

Expected behavior:

```text
2-node side serves writes
1-node side refuses writes
```

---

### 4.11 Node restart while sealed

Threat:

```text
Attacker restarts a node and tries to read stored secrets.
```

Controls:

```text
node boots sealed
KEK not active until unseal
secret operations return 503 while sealed
```

---

## 5. Out-of-scope threats

StrongBox does not fully protect against:

```text
root compromise of the host while unsealed
malicious kernel
malicious container runtime
compromised Docker daemon
attacker with live debugger access to unsealed process
compromised PostgreSQL admin account
client application leaking returned secrets
denial-of-service attacks
supply-chain compromise of openssl, argon2, bash, python, nginx, or postgres
physical access to the host
```

These are important limitations and should not be hidden.

---

## 6. Cryptographic assumptions

StrongBox relies on standard cryptographic tools instead of custom crypto.

Allowed primitives:

```text
AES-256-GCM from openssl
HMAC-SHA256 from openssl
Argon2id from argon2 CLI
CSPRNG from openssl rand or OS randomness
```

Do not implement AES, SHA, HMAC, or Argon2 manually.

Assumptions:

```text
nonce uniqueness is maintained for AES-GCM under each key
CSPRNG is functioning correctly
KEK is not written to disk in plaintext
audit HMAC key is protected
passwords are never stored in plaintext
```

---

## 7. Memory hygiene plan

Sensitive values:

```text
submitted shares
reconstructed master key
KEK
DEKs
plaintext secrets
raw bearer tokens
dynamic PostgreSQL passwords
```

Controls:

```text
store runtime state on tmpfs where possible
avoid command-line arguments for secret values
avoid environment variables for key material
unset Bash variables after use
remove temporary files immediately
overwrite Python bytearrays in shamir.py where practical
run Shamir reconstruction in short-lived process
never log key material
capture memory-clean evidence after unseal
```

Limitation:

```text
Because Bash strings are immutable from the script's perspective and may be copied internally, this implementation cannot make the same zeroization guarantee as carefully written C/Rust using locked memory and explicit zeroing.
```

The README must state this honestly.

---

## 8. Authentication and authorization risks

### Token storage

Raw tokens must not be stored.

Store:

```text
token ID
token hash/HMAC
policies
expiry
revoked flag
```

Return the raw token only once.

### Password storage

Passwords must be hashed using Argon2id.

Store:

```text
username
argon2id hash
assigned policies
```

Never store or log plaintext passwords.

---

## 9. Audit events to record

Minimum events:

```text
sys.init
sys.unseal.progress
sys.unseal.success
sys.seal
auth.login.success
auth.login.failure
auth.token.create
auth.token.revoke
auth.self
policy.write
policy.read
secret.write
secret.read
secret.delete
lease.create
lease.renew
lease.expire
lease.revoke
lease.revocation_pending
dynamic.postgres.create
dynamic.postgres.revoke
dynamic.postgres.revoke_failed
consensus.vote_request
consensus.vote_granted
consensus.leader_elected
consensus.heartbeat
consensus.write_commit
```

Avoid logging:

```text
secret plaintext
raw tokens
raw passwords
KEK
DEKs
master key
Shamir shares
dynamic PostgreSQL password
```

---

## 10. Failure-mode expectations

| Failure | Expected behavior |
|---|---|
| Vault sealed | Protected endpoints return 503. |
| Invalid token | Request returns 401. |
| Revoked token | Next request returns 401. |
| Valid token, wrong policy | Request returns 403. |
| Follower receives write | Reject/redirect with leader hint. |
| No majority | Refuse writes. |
| Leader killed before commit | Write fails cleanly. |
| Leader killed after commit | New leader preserves write. |
| Postgres down at lease expiry | Mark `revocation_pending` and retry. |
| Audit entry modified | Verifier exits non-zero and names index. |

---

## 11. Security review checklist

Before submission:

- [ ] No raw secret values in logs.
- [ ] Bearer token storage reviewed and minimized.
- [ ] Passwords hashed with Argon2id.
- [ ] KEK not stored in plaintext.
- [ ] Shamir shares not stored after unseal.
- [ ] Master key not stored after unseal.
- [ ] Revoked token checked on every request.
- [ ] Policies tested for allowed and denied paths.
- [ ] Dynamic PostgreSQL role is unique per read.
- [ ] Lease reaper retries failed revocations.
- [ ] Minority partition refuses writes.
- [ ] Audit verifier detects byte modification.
- [ ] README documents memory hygiene limitation honestly.

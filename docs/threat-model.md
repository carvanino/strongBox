# StrongBox Threat Model

## Protected Assets

- Secret plaintext values stored through `/v1/secrets/*`.
- In-memory KEK and reconstructed master key material.
- Shamir unseal shares and intermediate reconstruction buffers.
- Bearer tokens, password hashes, policies, and lease state.
- Dynamic PostgreSQL credentials and generated database roles.
- Audit log integrity and ordering.

## In Scope

- Detecting audit log tampering after a log entry is changed, removed, or
  reordered.
- Preventing use of revoked tokens immediately after revocation.
- Enforcing scoped token policies by path prefix and capability.
- Keeping the cluster sealed until the configured K-of-N unseal threshold is
  met.
- Refusing writes on minority partitions.
- Retrying dynamic credential revocation when PostgreSQL is temporarily
  unreachable.

## Out Of Scope

- A fully compromised root user on the host reading live process memory.
- Kernel-level malware, hypervisor compromise, or malicious Docker runtime.
- Physical attacks against the server.
- Long-term HSM/KMS backed key custody.
- Byzantine consensus faults; the election model assumes crash/partition faults,
  not actively malicious StrongBox nodes.
- Protecting secrets after plaintext has been returned to an authorized client.

## Audit Integrity Model

Each entry includes the previous entry hash, a SHA-256 hash of the canonical
entry payload, and an HMAC-SHA256 over that entry hash. A verifier with the same
in-memory audit key can identify the first corrupted entry by replaying the
chain from the genesis hash.

The audit HMAC key must be injected through process environment or another
memory-only secret channel. It must not be written to the audit log, container
volume, or verifier input file.

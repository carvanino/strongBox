# Required Screenshots

Capture these before final submission and link them from the main README:

1. `cluster-health.png` - `/v1/sys/health` showing the cluster initially sealed.
2. `unseal-progress.png` - sealed endpoint returns `503`, init returns shares, and unseal reaches `2/2`.
3. `secret-versioning.png` - first and second secret versions retrieved.
4. `policy-denied.png` - scoped token can read allowed path and is blocked from write/out-of-scope access.
5. `token-revocation.png` - revoked token returns `401` immediately after revoke.
6. `dynamic-postgres.png` - generated PostgreSQL role exists and can run `SELECT 1`.
7. `dynamic-postgres-cleanup.png` - generated role removed after DB outage recovery.
8. `audit-tamper.png` - `strongbox-verify` names the tampered entry and exits non-zero.
9. `audit-log-reset.png` - supporting evidence for rotating the old audit log after key-file support was added.

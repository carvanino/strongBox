# Required Screenshots

Capture these before final submission and link them from the main README:

1. `scenario-01-cluster-health-sealed.png` - `/v1/sys/health` showing the cluster initially sealed.
2. `scenario-02-unseal-progress.png` - sealed endpoint returns `503`, init returns shares, and unseal reaches `2/2`.
3. `scenario-03-secret-versioning.png` - first and second secret versions retrieved.
4. `scenario-04-policy-denied.png` - scoped token can read allowed path and is blocked from write/out-of-scope access.
5. `scenario-05-token-revocation.png` - revoked token returns `401` immediately after revoke.
6. `scenario-06-dynamic-postgres.png` - generated PostgreSQL role exists and can run `SELECT 1`.
7. `scenario-07-dynamic-postgres-cleanup.png` - generated role removed after DB outage recovery.
8. `scenario-08-leader-failover.png` - cluster elects a new leader and continues write/read after node1 is stopped.
9. `scenario-09-majority-partition.png` - two-node majority side continues write/read while node3 is stopped.
10. `scenario-10-audit-tamper.png` - `strongbox-verify` names the tampered entry and exits non-zero.
11. `support-audit-log-reset.png` - supporting evidence for rotating the old audit log after key-file support was added.

# Required Screenshots

Capture these before final submission and link them from the main README:

1. `cluster-health.png` - `/v1/sys/health` showing the cluster initially sealed.
2. `unseal-progress.png` - unseal progress showing `N/K`.
3. `memory-clean.png` - heap/process evidence showing no lingering key material.
4. `secret-versioning.png` - first and second secret versions retrieved.
5. `policy-denied.png` - scoped token blocked with 403.
6. `dynamic-postgres-cleanup.png` - generated role removed after DB outage recovery.
7. `audit-tamper.png` - `strongbox-verify` naming the tampered entry.

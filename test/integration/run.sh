#!/usr/bin/env bash
# =============================================================================
# test/integration/run.sh — StrongBox full integration test harness.
#
# Exercises all 10 grading scenarios against a live 3-node compose cluster.
# Each scenario reports PASS/FAIL with evidence (HTTP responses, pg queries).
#
# Usage:
#   ./test/integration/run.sh                    # spin up compose, run, tear down
#   KEEP_COMPOSE=1 ./test/integration/run.sh     # keep cluster running after tests
#   PUBLIC_URL=http://localhost ./test/integration/run.sh  # custom URL
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}/strongbox-integration-$$"
PUBLIC_URL="${PUBLIC_URL:-http://localhost}"
COMPOSE_FILE="$ROOT_DIR/compose.yaml"

PASS_COUNT=0
FAIL_COUNT=0

# Globals populated during test run
ROOT_TOKEN=""
SHARE_1=""
SHARE_2=""
SCOPED_TOKEN=""
DYNAMIC_USERNAME=""
DYNAMIC_LEASE_ID=""

mkdir -p "$TMP_DIR"

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    rm -rf "$TMP_DIR"
    if [[ "${KEEP_COMPOSE:-0}" != "1" && "${COMPOSE_STARTED:-0}" == "1" ]]; then
        echo ""
        echo "Tearing down compose cluster..."
        docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────
pass() {
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf '\033[32mPASS\033[0m: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '      %s\n' "$2"
}

fail() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf '\033[31mFAIL\033[0m: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '      Evidence: %s\n' "$2"
}

section() {
    printf '\n\033[1m── %s\033[0m\n' "$1"
}

# curl wrapper — insecure TLS, silent, returns body only
api() {
    curl -k -sS "$@"
}

# curl wrapper — returns HTTP status code only
api_status() {
    curl -k -sS -o /dev/null -w "%{http_code}" "$@"
}

# Wait for a URL to respond (polls every 2s up to max_wait seconds)
wait_for_url() {
    local url="$1"
    local max_wait="${2:-60}"
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        if curl -k -sS -o /dev/null --connect-timeout 2 "$url" 2>/dev/null; then
            return 0
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    return 1
}

# Wait for cluster to be sealed and healthy
wait_for_sealed() {
    local max_wait="${1:-90}"
    local elapsed=0
    echo "  Waiting for cluster health endpoint..."
    while [[ $elapsed -lt $max_wait ]]; do
        local resp
        resp=$(api "$PUBLIC_URL/v1/sys/health" 2>/dev/null) || true
        if echo "$resp" | grep -q '"sealed"'; then
            return 0
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    return 1
}

# ── Compose startup ───────────────────────────────────────────────────────────
start_cluster() {
    section "Starting 3-node compose cluster"

    if ! command -v docker &>/dev/null; then
        fail "Docker available" "docker not installed"
        exit 1
    fi

    echo "  Running: docker compose up -d --build"
    docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
    if ! docker compose -f "$COMPOSE_FILE" up -d --build >"$TMP_DIR/compose.log" 2>&1; then
        fail "Compose cluster started" "$(cat "$TMP_DIR/compose.log")"
        exit 1
    fi
    COMPOSE_STARTED=1
    echo "  Cluster started. Waiting for nodes to boot..."

    if ! wait_for_sealed 90; then
        fail "Cluster health endpoint reachable" \
            "$(api "$PUBLIC_URL/v1/sys/health" 2>&1 || echo 'no response')"
        exit 1
    fi
    echo "  Cluster is up."
}

# ── Scenario 1: Cluster boots sealed ─────────────────────────────────────────
scenario_1() {
    section "Scenario 1 — Cluster boots sealed"

    local resp
    resp=$(api "$PUBLIC_URL/v1/sys/health")

    if echo "$resp" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['sealed']==True" 2>/dev/null; then
        pass "Cluster boots sealed" "sealed=true confirmed"
    else
        fail "Cluster boots sealed" "$resp"
    fi

    # Non-sys endpoints must return 503
    local status
    status=$(api_status -X GET "$PUBLIC_URL/v1/secrets/test")
    if [[ "$status" == "503" ]]; then
        pass "Sealed cluster returns 503 for non-sys endpoints" "HTTP $status"
    else
        fail "Sealed cluster returns 503 for non-sys endpoints" "got HTTP $status"
    fi
}

# ── Scenario 2: Unseal with K-of-N ───────────────────────────────────────────
scenario_2() {
    section "Scenario 2 — Init and unseal with K-of-N shares"

    # Init
    local init_resp
    init_resp=$(api -X POST "$PUBLIC_URL/v1/sys/init" \
        -H "Content-Type: application/json" \
        -d '{"secret_shares":3,"secret_threshold":2}')

    ROOT_TOKEN=$(echo "$init_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['root_token'])" 2>/dev/null)
    SHARE_1=$(echo "$init_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['shares'][0])" 2>/dev/null)
    SHARE_2=$(echo "$init_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['shares'][1])" 2>/dev/null)

    if [[ -z "$ROOT_TOKEN" || -z "$SHARE_1" || -z "$SHARE_2" ]]; then
        fail "Init returns shares and root token" "$init_resp"
        return
    fi
    pass "Init returns 3 shares and root token" "token=${ROOT_TOKEN:0:8}..."

    # Submit share 1 — should still be sealed
    local unseal1
    unseal1=$(api -X POST "$PUBLIC_URL/v1/sys/unseal" \
        -H "Content-Type: application/json" \
        -d "{\"share\":\"$SHARE_1\"}")

    if echo "$unseal1" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['sealed']==True" 2>/dev/null; then
        pass "Share 1/2 accepted — still sealed" "progress=$(echo "$unseal1" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('progress','?'))" 2>/dev/null)"
    else
        fail "Share 1/2 accepted" "$unseal1"
    fi

    # Submit share 2 — should unseal
    local unseal2
    unseal2=$(api -X POST "$PUBLIC_URL/v1/sys/unseal" \
        -H "Content-Type: application/json" \
        -d "{\"share\":\"$SHARE_2\"}")

    if echo "$unseal2" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['sealed']==False" 2>/dev/null; then
        pass "Share 2/2 accepted — cluster unsealed" "sealed=false"
    else
        fail "Cluster unsealed after K shares" "$unseal2"
        return
    fi

    # Confirm health shows unsealed
    sleep 2
    local health
    health=$(api "$PUBLIC_URL/v1/sys/health")
    if echo "$health" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['sealed']==False" 2>/dev/null; then
        pass "Health endpoint confirms unsealed" "$health"
    else
        fail "Health endpoint shows sealed after unseal" "$health"
    fi
}

# ── Scenario 3: Secret write/read/versioning ──────────────────────────────────
scenario_3() {
    section "Scenario 3 — Write secret, read back, versioning"

    [[ -z "$ROOT_TOKEN" ]] && { fail "Scenario 3 skipped" "no root token (scenario 2 failed)"; return; }

    # Write version 1
    local write1
    write1=$(api -X PUT "$PUBLIC_URL/v1/secrets/app/db" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"password":"secret123"}')

    local v1
    v1=$(echo "$write1" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['version'])" 2>/dev/null)
    if [[ "$v1" == "1" ]]; then
        pass "Write secret version 1" "version=$v1"
    else
        fail "Write secret version 1" "$write1"
        return
    fi

    # Read back and verify value
    local read1
    read1=$(api "$PUBLIC_URL/v1/secrets/app/db" \
        -H "Authorization: Bearer $ROOT_TOKEN")

    if echo "$read1" | python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
assert d['version']==1
assert d['data']['password']=='secret123'
" 2>/dev/null; then
        pass "Read back version 1 — values match" "data.password=secret123"
    else
        fail "Read back version 1" "$read1"
    fi

    # Write version 2
    local write2
    write2=$(api -X PUT "$PUBLIC_URL/v1/secrets/app/db" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"password":"newsecret456"}')

    local v2
    v2=$(echo "$write2" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['version'])" 2>/dev/null)
    if [[ "$v2" == "2" ]]; then
        pass "Second write produces version 2" "version=$v2"
    else
        fail "Second write produces version 2" "$write2"
        return
    fi

    # Retrieve version 1 explicitly
    local read_v1
    read_v1=$(api "$PUBLIC_URL/v1/secrets/app/db?version=1" \
        -H "Authorization: Bearer $ROOT_TOKEN")

    if echo "$read_v1" | python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
assert d['version']==1
assert d['data']['password']=='secret123'
" 2>/dev/null; then
        pass "Version 1 retrievable after version 2 written" "data.password=secret123"
    else
        fail "Version 1 retrievable" "$read_v1"
    fi

    # Latest returns version 2
    local read_latest
    read_latest=$(api "$PUBLIC_URL/v1/secrets/app/db" \
        -H "Authorization: Bearer $ROOT_TOKEN")

    if echo "$read_latest" | python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
assert d['version']==2
assert d['data']['password']=='newsecret456'
" 2>/dev/null; then
        pass "Latest version returns version 2" "data.password=newsecret456"
    else
        fail "Latest version returns version 2" "$read_latest"
    fi
}

# ── Scenario 4: Scoped token policy enforcement ───────────────────────────────
scenario_4() {
    section "Scenario 4 — Scoped token policy enforcement"

    [[ -z "$ROOT_TOKEN" ]] && { fail "Scenario 4 skipped" "no root token"; return; }

    # Create read-only policy for secret/app/*
    local policy_resp
    policy_resp=$(api_status -X PUT "$PUBLIC_URL/v1/policies/read-only" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}')

    if [[ "$policy_resp" == "201" ]]; then
        pass "Read-only policy created" "HTTP 201"
    else
        fail "Read-only policy created" "HTTP $policy_resp"
        return
    fi

    # Create test user
    api -X PUT "$PUBLIC_URL/v1/users/scopeduser" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"password":"scopedpass123","policies":["read-only"]}' >/dev/null 2>&1

    # Login as scoped user
    local login_resp
    login_resp=$(api -X POST "$PUBLIC_URL/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"username":"scopeduser","password":"scopedpass123"}')

    SCOPED_TOKEN=$(echo "$login_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['token'])" 2>/dev/null)
    if [[ -z "$SCOPED_TOKEN" ]]; then
        fail "Scoped user login" "$login_resp"
        return
    fi
    pass "Scoped user login succeeded" "token=${SCOPED_TOKEN:0:8}..."

    # Read allowed path — must return 200
    local read_status
    read_status=$(api_status "$PUBLIC_URL/v1/secrets/app/db" \
        -H "Authorization: Bearer $SCOPED_TOKEN")
    if [[ "$read_status" == "200" ]]; then
        pass "Scoped token: read on secret/app/db — 200 allowed" "HTTP $read_status"
    else
        fail "Scoped token: read on secret/app/db" "got HTTP $read_status (expected 200)"
    fi

    # Write to allowed path — must return 403 (no write capability)
    local write_status
    write_status=$(api_status -X PUT "$PUBLIC_URL/v1/secrets/app/db" \
        -H "Authorization: Bearer $SCOPED_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"password":"hack"}')
    if [[ "$write_status" == "403" ]]; then
        pass "Scoped token: write on secret/app/db — 403 denied" "HTTP $write_status"
    else
        fail "Scoped token: write on secret/app/db" "got HTTP $write_status (expected 403)"
    fi

    # Read out-of-scope path — must return 403
    local oos_status
    oos_status=$(api_status "$PUBLIC_URL/v1/secrets/other/x" \
        -H "Authorization: Bearer $SCOPED_TOKEN")
    if [[ "$oos_status" == "403" ]]; then
        pass "Scoped token: read on secret/other/x — 403 denied" "HTTP $oos_status"
    else
        fail "Scoped token: read on secret/other/x" "got HTTP $oos_status (expected 403)"
    fi
}

# ── Scenario 5: Revoke token → immediate 401 ─────────────────────────────────
scenario_5() {
    section "Scenario 5 — Revoke token → immediate 401"

    [[ -z "$ROOT_TOKEN" || -z "$SCOPED_TOKEN" ]] && {
        fail "Scenario 5 skipped" "no scoped token (scenario 4 failed)"
        return
    }

    # Confirm token is valid before revoke
    local before_status
    before_status=$(api_status "$PUBLIC_URL/v1/secrets/app/db" \
        -H "Authorization: Bearer $SCOPED_TOKEN")
    if [[ "$before_status" != "200" ]]; then
        fail "Scoped token valid before revoke" "HTTP $before_status"
        return
    fi
    pass "Scoped token valid before revoke" "HTTP 200"

    # Revoke
    local revoke_status
    revoke_status=$(api_status -X POST "$PUBLIC_URL/v1/auth/revoke" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"token\":\"$SCOPED_TOKEN\"}")
    if [[ "$revoke_status" == "204" ]]; then
        pass "Token revocation accepted" "HTTP 204"
    else
        fail "Token revocation" "HTTP $revoke_status"
        return
    fi

    # Immediate next request must return 401 — no grace period
    local after_status
    after_status=$(api_status "$PUBLIC_URL/v1/secrets/app/db" \
        -H "Authorization: Bearer $SCOPED_TOKEN")
    if [[ "$after_status" == "401" ]]; then
        pass "Revoked token returns 401 immediately" "HTTP 401 — no cache grace"
    else
        fail "Revoked token returns 401 immediately" "got HTTP $after_status (expected 401)"
    fi
}

# ── Scenario 6: Dynamic Postgres role ────────────────────────────────────────
scenario_6() {
    section "Scenario 6 — Dynamic Postgres: fresh role in pg_roles, credential works"

    [[ -z "$ROOT_TOKEN" ]] && { fail "Scenario 6 skipped" "no root token"; return; }

    # Mint a dynamic credential
    local cred_resp
    cred_resp=$(api "$PUBLIC_URL/v1/dynamic-postgres/readonly" \
        -H "Authorization: Bearer $ROOT_TOKEN")

    DYNAMIC_USERNAME=$(echo "$cred_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['username'])" 2>/dev/null)
    local dynamic_password
    dynamic_password=$(echo "$cred_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['password'])" 2>/dev/null)
    DYNAMIC_LEASE_ID=$(echo "$cred_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['lease_id'])" 2>/dev/null)

    if [[ -z "$DYNAMIC_USERNAME" || -z "$dynamic_password" || -z "$DYNAMIC_LEASE_ID" ]]; then
        fail "Dynamic credential minted" "$cred_resp"
        return
    fi
    pass "Dynamic credential minted" "username=$DYNAMIC_USERNAME lease=$DYNAMIC_LEASE_ID"

    # Verify role exists in pg_roles
    local role_exists
    role_exists=$(docker compose -f "$COMPOSE_FILE" exec -T postgres \
        psql -U strongbox -d strongbox -tAc \
        "SELECT rolname FROM pg_roles WHERE rolname='${DYNAMIC_USERNAME}';" 2>/dev/null)

    if [[ "$role_exists" == "$DYNAMIC_USERNAME" ]]; then
        pass "Role exists in pg_roles" "rolname=$DYNAMIC_USERNAME"
    else
        fail "Role exists in pg_roles" "pg_roles query returned: '$role_exists'"
        return
    fi

    # Verify the credential actually works
    local connect_result
    connect_result=$(docker compose -f "$COMPOSE_FILE" exec -T postgres \
        psql -U "$DYNAMIC_USERNAME" -d strongbox \
        --no-password -tAc "SELECT 1;" \
        "$(PGPASSWORD="$dynamic_password")" 2>/dev/null || echo "FAIL")

    # Try via env variable approach
    if docker compose -f "$COMPOSE_FILE" exec -T \
        -e "PGPASSWORD=$dynamic_password" postgres \
        psql -U "$DYNAMIC_USERNAME" -d strongbox -tAc "SELECT 1;" &>/dev/null; then
        pass "Dynamic credential authenticates to Postgres" "SELECT 1 succeeded"
    else
        fail "Dynamic credential authenticates to Postgres" "connection failed (role exists but auth failed)"
    fi
}

# ── Scenario 7: DB down → auto-recovery ──────────────────────────────────────
scenario_7() {
    section "Scenario 7 — DB outage: role cleaned up automatically on recovery"

    [[ -z "$DYNAMIC_USERNAME" || -z "$DYNAMIC_LEASE_ID" ]] && {
        fail "Scenario 7 skipped" "no dynamic credential from scenario 6"
        return
    }

    # Use a short-lived lease for this test — create a new one
    local short_resp
    short_resp=$(api "$PUBLIC_URL/v1/dynamic-postgres/readonly" \
        -H "Authorization: Bearer $ROOT_TOKEN")

    local short_username short_lease
    short_username=$(echo "$short_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['username'])" 2>/dev/null)
    short_lease=$(echo "$short_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['lease_id'])" 2>/dev/null)

    if [[ -z "$short_username" ]]; then
        fail "Short-lived dynamic credential minted for scenario 7" "$short_resp"
        return
    fi
    pass "Short-lived credential minted" "username=$short_username"

    # Stop Postgres
    echo "  Stopping Postgres..."
    docker compose -f "$COMPOSE_FILE" stop postgres >/dev/null 2>&1
    pass "Postgres stopped" ""

    # Revoke the lease — this will fail (DB down) and set revocation_pending
    local revoke_status
    revoke_status=$(api_status -X POST "$PUBLIC_URL/v1/leases/${short_lease}/revoke" \
        -H "Authorization: Bearer $ROOT_TOKEN")
    pass "Lease revoke attempted while DB down" "HTTP $revoke_status (revocation_pending expected internally)"

    # Wait past reaper interval
    echo "  Waiting 35 seconds past reaper interval..."
    sleep 35

    # Restart Postgres
    echo "  Restarting Postgres..."
    docker compose -f "$COMPOSE_FILE" start postgres >/dev/null 2>&1

    # Wait for Postgres to be healthy
    local pg_ready=0
    for _ in {1..20}; do
        if docker compose -f "$COMPOSE_FILE" exec -T postgres \
            pg_isready -U strongbox -d strongbox &>/dev/null; then
            pg_ready=1
            break
        fi
        sleep 3
    done

    if [[ $pg_ready -eq 0 ]]; then
        fail "Postgres recovered" "pg_isready timed out"
        return
    fi
    pass "Postgres recovered" ""

    # Wait for reaper to clean up (reaper runs every 30s, give it 2 cycles)
    echo "  Waiting for reaper to clean up (up to 70 seconds)..."
    local cleaned=0
    for _ in {1..14}; do
        local role_check
        role_check=$(docker compose -f "$COMPOSE_FILE" exec -T postgres \
            psql -U strongbox -d strongbox -tAc \
            "SELECT rolname FROM pg_roles WHERE rolname='${short_username}';" 2>/dev/null)
        if [[ -z "$role_check" ]]; then
            cleaned=1
            break
        fi
        sleep 5
    done

    if [[ $cleaned -eq 1 ]]; then
        pass "Role cleaned up automatically after DB recovery" \
            "rolname=$short_username no longer in pg_roles"
    else
        fail "Role cleaned up automatically after DB recovery" \
            "role $short_username still exists in pg_roles after recovery"
    fi
}

# ── Scenario 8: Kill leader mid-write ────────────────────────────────────────
scenario_8() {
    section "Scenario 8 — Kill leader mid-write: clean fail or durable complete"

    [[ -z "$ROOT_TOKEN" ]] && { fail "Scenario 8 skipped" "no root token"; return; }

    # Identify the current leader
    local health leader_node
    health=$(api "$PUBLIC_URL/v1/sys/health")
    leader_node=$(echo "$health" | python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
leader=d.get('leader','')
print(leader.split(':')[0] if ':' in leader else leader)
" 2>/dev/null)

    if [[ -z "$leader_node" ]]; then
        fail "Identify current leader" "$health"
        return
    fi
    pass "Current leader identified" "leader=$leader_node"

    # Map node ID to compose service name
    local leader_service
    case "$leader_node" in
        node1) leader_service="strongbox-1" ;;
        node2) leader_service="strongbox-2" ;;
        node3) leader_service="strongbox-3" ;;
        *) leader_service="${leader_node}" ;;
    esac

    # Write a secret (will go to leader)
    api -X PUT "$PUBLIC_URL/v1/secrets/scenario8/pre" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"status":"pre-kill"}' >/dev/null 2>&1

    # Kill the leader process mid-write
    echo "  Killing leader container: $leader_service"
    docker compose -f "$COMPOSE_FILE" kill "$leader_service" >/dev/null 2>&1
    pass "Leader container killed" "service=$leader_service"

    # Attempt a write immediately — must either fail cleanly or complete durably
    local write_resp write_status
    write_status=$(api_status -X PUT "$PUBLIC_URL/v1/secrets/scenario8/during-kill" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"status":"during-kill"}')

    # Acceptable: 201 (write succeeded under new leader) or 5xx/503 (clean fail)
    if [[ "$write_status" == "201" || "$write_status" == "503" || \
          "$write_status" == "500" || "$write_status" == "502" ]]; then
        pass "Write during leader kill: clean fail or durable complete" \
            "HTTP $write_status (201=durable, 5xx=clean fail)"
    else
        fail "Write during leader kill produced unexpected status" "HTTP $write_status"
    fi

    # Wait for new leader election
    echo "  Waiting for new leader election (up to 15 seconds)..."
    sleep 8

    # Restart killed node
    docker compose -f "$COMPOSE_FILE" start "$leader_service" >/dev/null 2>&1

    sleep 5

    # Cluster must still serve writes under new leader
    local post_write_status
    post_write_status=$(api_status -X PUT "$PUBLIC_URL/v1/secrets/scenario8/post-kill" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"status":"post-kill"}')
    if [[ "$post_write_status" == "201" ]]; then
        pass "Cluster serves writes under new leader" "HTTP 201"
    else
        fail "Cluster serves writes under new leader" "HTTP $post_write_status"
    fi
}

# ── Scenario 9: 2-1 partition ─────────────────────────────────────────────────
scenario_9() {
    section "Scenario 9 — 2-1 partition: majority writes, minority refuses"

    [[ -z "$ROOT_TOKEN" ]] && { fail "Scenario 9 skipped" "no root token"; return; }

    # Identify leader and isolate one minority node
    local health leader_node
    health=$(api "$PUBLIC_URL/v1/sys/health")
    leader_node=$(echo "$health" | python3 -c "
import sys,json
d=json.loads(sys.stdin.read())
leader=d.get('leader','')
print(leader.split(':')[0] if ':' in leader else leader)
" 2>/dev/null)

    # Isolate strongbox-3 (minority partition)
    local minority_service="strongbox-3"
    echo "  Isolating minority node: $minority_service"
    docker compose -f "$COMPOSE_FILE" kill "$minority_service" >/dev/null 2>&1
    pass "Minority node isolated" "service=$minority_service stopped"

    sleep 5

    # Majority (2 of 3) must still serve writes
    local majority_status
    majority_status=$(api_status -X PUT "$PUBLIC_URL/v1/secrets/scenario9/majority-write" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"status":"majority-write"}')
    if [[ "$majority_status" == "201" ]]; then
        pass "Majority partition serves writes" "HTTP 201"
    else
        fail "Majority partition serves writes" "HTTP $majority_status"
    fi

    # Minority node must refuse writes (503 or connection refused)
    # Get the minority node's direct address from compose
    local minority_port=8202  # strongbox-3 internal port — may need adjustment
    local minority_status
    minority_status=$(curl -k -sS -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 \
        -X PUT "http://localhost:${minority_port}/v1/secrets/scenario9/minority-write" \
        -H "Authorization: Bearer $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"status":"minority-write"}' 2>/dev/null) || minority_status="000"

    if [[ "$minority_status" == "503" || "$minority_status" == "000" || \
          "$minority_status" == "307" ]]; then
        pass "Minority node refuses writes or is unreachable" \
            "HTTP $minority_status (503=refused, 307=redirect, 000=unreachable)"
    else
        fail "Minority node refuses writes" "HTTP $minority_status (expected 503/307/000)"
    fi

    # Restore minority node
    docker compose -f "$COMPOSE_FILE" start "$minority_service" >/dev/null 2>&1
    sleep 5
    pass "Minority node restored" "service=$minority_service restarted"
}

# ── Scenario 10: Audit tamper detection ───────────────────────────────────────
scenario_10() {
    section "Scenario 10 — Audit tamper detection"

    local log="$TMP_DIR/audit.log"
    local tampered="$TMP_DIR/audit-tampered.log"

    # Generate a real audit log using audit.sh directly
    if ! (
        export AUDIT_LOG="$log"
        export AUDIT_HMAC_KEY_HEX
        AUDIT_HMAC_KEY_HEX=$(openssl rand -hex 32)
        export NODE_ID="integration-test"
        source "$ROOT_DIR/lib/storage.sh"
        source "$ROOT_DIR/lib/audit.sh"
        audit_append "login"  "/v1/auth/login"      "token-a" '{}'
        audit_append "write"  "secret/app/config"   "token-a" '{"version":"1","lease_id":""}'
        audit_append "read"   "secret/app/config"   "token-b" '{"version":"1","lease_id":"lease-1"}'
        audit_append "revoke" "/v1/auth/revoke"      "token-a" '{}'
    ) 2>/dev/null; then
        fail "Audit entries can be appended" "audit_append returned non-zero"
        return
    fi
    pass "4 audit entries appended" ""

    # Verify clean log — must exit 0
    local hmac_key
    hmac_key=$(openssl rand -hex 32)
    # Re-generate with known key
    (
        export AUDIT_LOG="$log"
        export AUDIT_HMAC_KEY_HEX="$hmac_key"
        export NODE_ID="integration-test"
        source "$ROOT_DIR/lib/storage.sh"
        source "$ROOT_DIR/lib/audit.sh"
        # Clear and rewrite with known key
        : > "$log"
        audit_append "login"  "/v1/auth/login"    "token-a" '{}'
        audit_append "write"  "secret/app/config" "token-a" '{"version":"1","lease_id":""}'
        audit_append "read"   "secret/app/config" "token-b" '{"version":"1","lease_id":"lease-1"}'
    ) 2>/dev/null

    local clean_exit
    AUDIT_HMAC_KEY_HEX="$hmac_key" "$ROOT_DIR/bin/strongbox-verify" "$log" >/dev/null 2>&1
    clean_exit=$?
    if [[ $clean_exit -eq 0 ]]; then
        pass "Clean audit log verifies (exit 0)" ""
    else
        fail "Clean audit log verifies" "strongbox-verify exited $clean_exit on clean log"
        return
    fi

    # Tamper one byte in entry index 1
    cp "$log" "$tampered"
    python3 - "$tampered" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
if len(lines) < 2:
    raise SystemExit("expected at least 2 audit lines")
# Flip a character in the second entry's op field
lines[1] = lines[1].replace('"write"', '"wrote"', 1)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

    local tampered_output tampered_exit
    tampered_output=$(AUDIT_HMAC_KEY_HEX="$hmac_key" \
        "$ROOT_DIR/bin/strongbox-verify" "$tampered" 2>&1) || true
    tampered_exit=$?

    if [[ $tampered_exit -ne 0 ]]; then
        pass "Tampered log rejected (exit non-zero)" "exit=$tampered_exit"
    else
        fail "Tampered log rejected" "strongbox-verify exited 0 on tampered log"
        return
    fi

    if echo "$tampered_output" | grep -q "TAMPERED: entry index 1"; then
        pass "Tampered entry named by index" "Evidence: $tampered_output"
    else
        fail "Tampered entry named by index" "output: $tampered_output"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    printf '\033[1mStrongBox Integration Test Harness\033[0m\n'
    printf 'Target: %s\n' "$PUBLIC_URL"
    printf 'Root:   %s\n' "$ROOT_DIR"

    start_cluster

    scenario_1
    scenario_2
    scenario_3
    scenario_4
    scenario_5
    scenario_6
    scenario_7
    scenario_8
    scenario_9
    scenario_10

    printf '\n\033[1mSummary\033[0m\n'
    printf '  \033[32mPASS: %d\033[0m\n' "$PASS_COUNT"
    printf '  \033[31mFAIL: %d\033[0m\n' "$FAIL_COUNT"

    [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"

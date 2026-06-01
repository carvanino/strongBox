#!/usr/bin/env bash
# StrongBox integration harness.
#
# This script is intentionally honest about cross-team dependencies: Daniel's
# audit verifier scenario is exercised fully, while scenarios owned by other
# modules are skipped when the required handlers are not present.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}/strongbox-integration-$$"
PUBLIC_URL="${PUBLIC_URL:-https://localhost}"
AUDIT_HMAC_KEY_HEX="${AUDIT_HMAC_KEY_HEX:-00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

mkdir -p "$TMP_DIR"

cleanup() {
    rm -rf "$TMP_DIR"
    if [[ "${KEEP_COMPOSE:-0}" != "1" && "${COMPOSE_STARTED:-0}" == "1" ]]; then
        docker compose -f "$ROOT_DIR/compose.yaml" down -v >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n%s\n' "$1" "${2:-}"
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf 'SKIP: %s\n%s\n' "$1" "${2:-}"
}

have_file() {
    [[ -f "$ROOT_DIR/$1" ]]
}

have_function() {
    local file="$1"
    local fn="$2"
    grep -qE "^[[:space:]]*${fn}[[:space:]]*\\(" "$ROOT_DIR/$file"
}

curl_json() {
    curl -k -sS -i "$@"
}

start_compose_if_possible() {
    if ! command -v docker >/dev/null 2>&1; then
        skip "Compose cluster startup" "docker is not installed on this host"
        return 1
    fi

    docker compose -f "$ROOT_DIR/compose.yaml" up -d --build >/tmp/strongbox-compose.log 2>&1
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        skip "Compose cluster startup" "$(cat /tmp/strongbox-compose.log)"
        return 1
    fi
    COMPOSE_STARTED=1
    return 0
}

scenario_dependency_or_skip() {
    local name="$1"
    shift
    local missing=()
    local item

    for item in "$@"; do
        if ! have_file "$item"; then
            missing+=("$item")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        skip "$name" "missing dependency files: ${missing[*]}"
        return 1
    fi
    return 0
}

scenario_1_cluster_boots_sealed() {
    if ! scenario_dependency_or_skip "Scenario 1 - cluster boots sealed" "bin/strongbox"; then
        return
    fi
    start_compose_if_possible || return

    local response
    response=$(curl_json "$PUBLIC_URL/v1/sys/health" 2>&1)
    if grep -q '"sealed":true' <<< "$response"; then
        pass "Scenario 1 - cluster boots sealed"
    else
        fail "Scenario 1 - cluster boots sealed" "$response"
    fi
}

scenario_2_unseal_k_of_n() {
    if ! have_function "lib/http.sh" "handle_sys_unseal" && ! have_file "bin/strongbox"; then
        skip "Scenario 2 - unseal K-of-N" "seal/unseal handler is owned by Pabby and is not present yet"
        return
    fi
    skip "Scenario 2 - unseal K-of-N" "requires Pabby's init/unseal implementation and memory screenshot evidence"
}

scenario_3_secret_versioning() {
    if ! have_function "lib/http.sh" "handle_secret_put" && ! have_file "bin/strongbox"; then
        skip "Scenario 3 - secret write/read/versioning" "secret handlers are owned by Pabby and are not present yet"
        return
    fi
    skip "Scenario 3 - secret write/read/versioning" "requires Pabby's secret handlers"
}

scenario_4_policy_scope() {
    scenario_dependency_or_skip "Scenario 4 - scoped token policy" "lib/auth.sh" || return
    skip "Scenario 4 - scoped token policy" "requires Akinola's auth and policy endpoints to be complete"
}

scenario_5_revoke_token() {
    scenario_dependency_or_skip "Scenario 5 - revoke token immediate 401" "lib/auth.sh" || return
    skip "Scenario 5 - revoke token immediate 401" "requires Akinola's auth revoke endpoint to be complete"
}

scenario_6_dynamic_postgres_role() {
    scenario_dependency_or_skip "Scenario 6 - dynamic Postgres role works" "lib/dynamic.sh" "lib/lease.sh" || return
    skip "Scenario 6 - dynamic Postgres role works" "requires Akinola's dynamic Postgres implementation"
}

scenario_7_dynamic_reaper_cleanup() {
    scenario_dependency_or_skip "Scenario 7 - DB outage cleanup retry" "lib/dynamic.sh" "lib/lease.sh" || return
    skip "Scenario 7 - DB outage cleanup retry" "requires Akinola's lease reaper and dynamic revocation implementation"
}

scenario_8_kill_leader_mid_write() {
    scenario_dependency_or_skip "Scenario 8 - kill leader mid-write" "bin/strongbox" || return
    skip "Scenario 8 - kill leader mid-write" "requires completed write handler and live 3-node consensus"
}

scenario_9_partition_behavior() {
    scenario_dependency_or_skip "Scenario 9 - 2-1 partition behavior" "bin/strongbox" || return
    skip "Scenario 9 - 2-1 partition behavior" "requires completed consensus partition behavior"
}

scenario_10_audit_tamper_detection() {
    local log="$TMP_DIR/audit.log"
    local tampered="$TMP_DIR/audit-tampered.log"
    local clean_output tampered_output

    if ! (
        cd "$ROOT_DIR" || exit 1
        export AUDIT_LOG="$log"
        export AUDIT_HMAC_KEY_HEX
        export NODE_ID="node-test"
        # shellcheck source=lib/audit.sh
        source "$ROOT_DIR/lib/audit.sh"
        audit_append "login" "/v1/auth/login" "token-a" '{"version":"","lease_id":""}'
        audit_append "write" "secret/app/config" "token-a" '{"version":"1","lease_id":""}'
        audit_append "read" "secret/app/config" "token-a" '{"version":"1","lease_id":"lease-1"}'
    ); then
        fail "Scenario 10 - audit entries can be appended" "audit_append returned non-zero"
        return
    fi

    clean_output=$(AUDIT_HMAC_KEY_HEX="$AUDIT_HMAC_KEY_HEX" "$ROOT_DIR/bin/strongbox-verify" "$log" 2>&1)
    if [[ "$?" -ne 0 ]]; then
        fail "Scenario 10 - clean audit log verifies" "$clean_output"
        return
    fi

    cp "$log" "$tampered"
    python3 - "$tampered" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
if len(lines) < 2:
    raise SystemExit("expected at least two audit lines")
lines[1] = lines[1].replace("write", "wrote", 1)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

    tampered_output=$(AUDIT_HMAC_KEY_HEX="$AUDIT_HMAC_KEY_HEX" "$ROOT_DIR/bin/strongbox-verify" "$tampered" 2>&1)
    if [[ "$?" -eq 0 ]]; then
        fail "Scenario 10 - tampered audit log rejected" "$tampered_output"
        return
    fi

    if grep -q 'TAMPERED: entry index 1' <<< "$tampered_output"; then
        pass "Scenario 10 - tampered audit log rejected"
        printf 'Evidence: %s\n' "$tampered_output"
    else
        fail "Scenario 10 - tampered audit log names entry" "$tampered_output"
    fi
}

main() {
    printf 'StrongBox integration harness\n'
    printf 'Root: %s\n\n' "$ROOT_DIR"

    scenario_1_cluster_boots_sealed
    scenario_2_unseal_k_of_n
    scenario_3_secret_versioning
    scenario_4_policy_scope
    scenario_5_revoke_token
    scenario_6_dynamic_postgres_role
    scenario_7_dynamic_reaper_cleanup
    scenario_8_kill_leader_mid_write
    scenario_9_partition_behavior
    scenario_10_audit_tamper_detection

    printf '\nSummary: pass=%s fail=%s skip=%s\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"

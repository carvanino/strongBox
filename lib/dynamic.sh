#!/bin/bash
# lib/dynamic.sh — Dynamic PostgreSQL credential engine

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/storage.sh"
# Note: lease.sh is NOT sourced here to avoid circular dependency.
# lease_create must be available in the caller's environment (sourced by bin/strongbox).

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
DYNAMIC_LEASE_TTL="${DYNAMIC_LEASE_TTL:-3600}"
DYNAMIC_MAX_TTL="${DYNAMIC_MAX_TTL:-86400}"

_generate_username() {
    local prefix="${1:-role}"
    echo "sb_${prefix}_$(openssl rand -hex 4)"
}

_generate_password() {
    openssl rand -base64 24 | tr -d '=/+'
}

_psql_exec() {
    export PGPASSWORD="$POSTGRES_PASSWORD"
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
         -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
         -c "$1" -q --no-password 2>/dev/null
}

_pg_reachable() {
    export PGPASSWORD="$POSTGRES_PASSWORD"
    psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
         -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
         -c "SELECT 1;" -q --no-password &>/dev/null
}

dynamic_init() {
    command -v psql &>/dev/null || { echo "[dynamic] psql not found" >&2; return 1; }
    _pg_reachable && echo "[dynamic] Postgres connected" >&2 || \
        echo "[dynamic] WARNING: Postgres unreachable at startup" >&2
}

dynamic_mint_role() {
    local role_name="${1:-role}" grants="${2:-}"
    local username password
    username=$(_generate_username "$role_name")
    password=$(_generate_password)

    local valid_until
    valid_until=$(date -u -d "+$(( DYNAMIC_LEASE_TTL + 300 )) seconds" \
        '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
        date -u -v "+$(( DYNAMIC_LEASE_TTL + 300 ))S" '+%Y-%m-%d %H:%M:%S')

    if ! _psql_exec "CREATE ROLE \"${username}\" WITH LOGIN PASSWORD '${password}' VALID UNTIL '${valid_until}';"; then
        echo "[dynamic] Failed to CREATE ROLE ${username}" >&2
        return 1
    fi

    if [[ -n "$grants" ]]; then
        if ! _psql_exec "${grants} \"${username}\";"; then
            _psql_exec "DROP ROLE IF EXISTS \"${username}\";" 2>/dev/null || true
            echo "[dynamic] Failed to GRANT to ${username}" >&2
            return 1
        fi
    fi

    local lease_id
    lease_id=$(lease_create "dynamic-postgres/${role_name}" "$DYNAMIC_LEASE_TTL" "dynamic" "$username")

    printf '{"username":"%s","password":"%s","lease_id":"%s","ttl":%d}\n' \
        "$username" "$password" "$lease_id" "$DYNAMIC_LEASE_TTL"

    unset password
}

dynamic_revoke_role() {
    local username="$1"

    if ! _pg_reachable; then
        echo "[dynamic] DB unreachable — cannot revoke ${username}" >&2
        return 1
    fi

    _psql_exec "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"${username}\";"    2>/dev/null || true
    _psql_exec "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"${username}\";" 2>/dev/null || true
    _psql_exec "REVOKE CONNECT ON DATABASE \"${POSTGRES_DB}\" FROM \"${username}\";"          2>/dev/null || true

    if ! _psql_exec "DROP ROLE IF EXISTS \"${username}\";"; then
        echo "[dynamic] Failed to DROP ROLE ${username}" >&2
        return 1
    fi

    echo "[dynamic] Dropped role ${username}" >&2
    return 0
}
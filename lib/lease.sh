#!/bin/bash
# lib/lease.sh — Leasing, TTLs, background reaper

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/storage.sh"

DEFAULT_TTL="${DEFAULT_LEASE_TTL:-3600}"
MAX_TTL="${MAX_LEASE_TTL:-86400}"
REAPER_INTERVAL="${REAPER_INTERVAL:-30}"
BACKOFF_INITIAL="${BACKOFF_INITIAL:-2}"
BACKOFF_MAX="${BACKOFF_MAX:-60}"

_generate_lease_id() { openssl rand -hex 16; }
_now()               { date +%s; }

lease_init() { _start_reaper & disown; }

lease_create() {
    local path="$1" ttl="${2:-$DEFAULT_TTL}" lease_type="${3:-static}" pg_role="${4:-}"
    [[ $ttl -gt $MAX_TTL ]] && ttl=$MAX_TTL
    local lease_id now
    lease_id=$(_generate_lease_id); now=$(_now)
    storage_put "lease:${lease_id}:path"       "$path"
    storage_put "lease:${lease_id}:state"      "active"
    storage_put "lease:${lease_id}:created_at" "$now"
    storage_put "lease:${lease_id}:ttl"        "$ttl"
    storage_put "lease:${lease_id}:max_ttl"    "$MAX_TTL"
    storage_put "lease:${lease_id}:type"       "$lease_type"
    [[ -n "$pg_role" ]] && storage_put "lease:${lease_id}:pg_role" "$pg_role"
    echo "$lease_id"
}

lease_get_state() {
    local lease_id="$1" current_state
    current_state=$(storage_get "lease:${lease_id}:state" 2>/dev/null) || { echo "unknown"; return 1; }
    if [[ "$current_state" == "active" ]]; then
        local created_at ttl now
        created_at=$(storage_get "lease:${lease_id}:created_at")
        ttl=$(storage_get "lease:${lease_id}:ttl")
        now=$(_now)
        if [[ $(( created_at + ttl )) -le $now ]]; then
            storage_put "lease:${lease_id}:state" "expired"
            current_state="expired"
        fi
    fi
    echo "$current_state"
}

lease_get() {
    local lease_id="$1"
    local path state created_at ttl max_ttl lease_type
    path=$(storage_get       "lease:${lease_id}:path"       2>/dev/null) || { echo "null"; return 1; }
    state=$(lease_get_state  "$lease_id")
    created_at=$(storage_get "lease:${lease_id}:created_at" 2>/dev/null) || created_at=0
    ttl=$(storage_get        "lease:${lease_id}:ttl"        2>/dev/null) || ttl=0
    max_ttl=$(storage_get    "lease:${lease_id}:max_ttl"    2>/dev/null) || max_ttl=0
    lease_type=$(storage_get "lease:${lease_id}:type"       2>/dev/null) || lease_type="static"
    local now ttl_remaining
    now=$(_now); ttl_remaining=$(( created_at + ttl - now ))
    [[ $ttl_remaining -lt 0 ]] && ttl_remaining=0
    printf '{"lease_id":"%s","path":"%s","state":"%s","ttl_remaining":%d,"max_ttl":%d,"type":"%s"}\n' \
        "$lease_id" "$path" "$state" "$ttl_remaining" "$max_ttl" "$lease_type"
}

lease_renew() {
    local lease_id="$1"
    local state; state=$(lease_get_state "$lease_id")
    [[ "$state" != "active" ]] && { echo "FAIL"; return 1; }
    local created_at max_ttl now time_used max_remaining new_ttl
    created_at=$(storage_get "lease:${lease_id}:created_at")
    max_ttl=$(storage_get    "lease:${lease_id}:max_ttl")
    now=$(_now)
    time_used=$(( now - created_at ))
    max_remaining=$(( max_ttl - time_used ))
    [[ $max_remaining -le 0 ]] && { echo "FAIL"; return 1; }
    new_ttl=$DEFAULT_TTL
    [[ $new_ttl -gt $max_remaining ]] && new_ttl=$max_remaining
    storage_put "lease:${lease_id}:created_at" "$now"
    storage_put "lease:${lease_id}:ttl"        "$new_ttl"
    echo "$new_ttl"
}

lease_revoke() {
    local lease_id="$1"
    local lease_type pg_role
    lease_type=$(storage_get "lease:${lease_id}:type"    2>/dev/null) || lease_type="static"
    pg_role=$(storage_get    "lease:${lease_id}:pg_role" 2>/dev/null) || pg_role=""
    if [[ "$lease_type" == "dynamic" ]] && [[ -n "$pg_role" ]]; then
        source "$SCRIPT_DIR/dynamic.sh"
        if ! dynamic_revoke_role "$pg_role" "$lease_id"; then
            storage_put "lease:${lease_id}:state"         "revocation_pending"
            storage_put "lease:${lease_id}:retry_wait"    "$BACKOFF_INITIAL"
            storage_put "lease:${lease_id}:next_retry_at" "$(( $(_now) + BACKOFF_INITIAL ))"
            return 0
        fi
    fi
    storage_put "lease:${lease_id}:state" "revoked"
}

_start_reaper() {
    while true; do _reaper_tick; sleep "$REAPER_INTERVAL"; done
}

_reaper_tick() {
    local all_keys lease_ids
    all_keys=$(storage_list "lease:" 2>/dev/null) || return 0
    lease_ids=$(echo "$all_keys" | grep -oP 'lease:\K[^:]+' | sort -u 2>/dev/null) || return 0
    while IFS= read -r lease_id; do
        [[ -z "$lease_id" ]] && continue
        _reaper_process "$lease_id"
    done <<< "$lease_ids"
}

_reaper_process() {
    local lease_id="$1"
    local state; state=$(lease_get_state "$lease_id" 2>/dev/null) || return 0
    case "$state" in
        expired)            _reaper_revoke "$lease_id" ;;
        revocation_pending) _reaper_retry  "$lease_id" ;;
    esac
}

_reaper_revoke() {
    local lease_id="$1"
    local lease_type pg_role
    lease_type=$(storage_get "lease:${lease_id}:type"    2>/dev/null) || lease_type="static"
    pg_role=$(storage_get    "lease:${lease_id}:pg_role" 2>/dev/null) || pg_role=""
    if [[ "$lease_type" == "dynamic" ]] && [[ -n "$pg_role" ]]; then
        source "$SCRIPT_DIR/dynamic.sh"
        if dynamic_revoke_role "$pg_role" "$lease_id"; then
            storage_put "lease:${lease_id}:state" "revoked"
        else
            storage_put "lease:${lease_id}:state"         "revocation_pending"
            storage_put "lease:${lease_id}:retry_wait"    "$BACKOFF_INITIAL"
            storage_put "lease:${lease_id}:next_retry_at" "$(( $(_now) + BACKOFF_INITIAL ))"
        fi
    else
        storage_put "lease:${lease_id}:state" "revoked"
    fi
}

_reaper_retry() {
    local lease_id="$1"
    local next_retry_at now
    next_retry_at=$(storage_get "lease:${lease_id}:next_retry_at" 2>/dev/null) || next_retry_at=0
    now=$(_now)
    [[ $now -lt $next_retry_at ]] && return 0
    local pg_role; pg_role=$(storage_get "lease:${lease_id}:pg_role" 2>/dev/null) || return 0
    [[ -z "$pg_role" ]] && return 0
    source "$SCRIPT_DIR/dynamic.sh"
    if dynamic_revoke_role "$pg_role" "$lease_id"; then
        storage_put "lease:${lease_id}:state" "revoked"
    else
        local current_wait next_wait
        current_wait=$(storage_get "lease:${lease_id}:retry_wait" 2>/dev/null) || current_wait=$BACKOFF_INITIAL
        next_wait=$(( current_wait * 2 ))
        [[ $next_wait -gt $BACKOFF_MAX ]] && next_wait=$BACKOFF_MAX
        storage_put "lease:${lease_id}:retry_wait"    "$next_wait"
        storage_put "lease:${lease_id}:next_retry_at" "$(( now + next_wait ))"
    fi
}
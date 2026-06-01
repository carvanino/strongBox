#!/usr/bin/env bash
# Tamper-evident audit log for StrongBox.
#
# Contract:
#   audit_append OP PATH TOKEN_ID [EXTRA_JSON_OBJECT]
#   audit_query_by_token TOKEN_ID
#   handle_audit_query QUERY TOKEN
#
# The audit HMAC key is supplied through AUDIT_HMAC_KEY_HEX and is never
# persisted by this module.

set -uo pipefail

AUDIT_LOG="${AUDIT_LOG:-/data/audit/audit.log}"
AUDIT_GENESIS_HASH="${AUDIT_GENESIS_HASH:-0000000000000000000000000000000000000000000000000000000000000000}"

audit_init() {
    mkdir -p "$(dirname "$AUDIT_LOG")"
    touch "$AUDIT_LOG"
}

audit_require_key() {
    if [[ -z "${AUDIT_HMAC_KEY_HEX:-}" ]]; then
        echo "ERROR: AUDIT_HMAC_KEY_HEX is required" >&2
        return 1
    fi
    if [[ ! "$AUDIT_HMAC_KEY_HEX" =~ ^[0-9a-fA-F]+$ || $(( ${#AUDIT_HMAC_KEY_HEX} % 2 )) -ne 0 ]]; then
        echo "ERROR: AUDIT_HMAC_KEY_HEX must be even-length hex" >&2
        return 1
    fi
}

audit_lock() {
    local lock_dir="${AUDIT_LOG}.lock"
    while ! mkdir "$lock_dir" 2>/dev/null; do
        sleep 0.05
    done
    AUDIT_LOCK_DIR="$lock_dir"
}

audit_unlock() {
    if [[ -n "${AUDIT_LOCK_DIR:-}" ]]; then
        rmdir "$AUDIT_LOCK_DIR" 2>/dev/null || true
        AUDIT_LOCK_DIR=""
    fi
}

audit_last_hash() {
    audit_init
    if [[ ! -s "$AUDIT_LOG" ]]; then
        printf '%s\n' "$AUDIT_GENESIS_HASH"
        return 0
    fi

    tail -n 1 "$AUDIT_LOG" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["entry_hash"])'
}

audit_append() {
    local op="$1"
    local path="$2"
    local token_id="$3"
    local extra_json="{}"
    local prev_hash line

    if [[ "$#" -ge 4 ]]; then
        extra_json="$4"
    fi

    audit_require_key || return 1
    audit_init
    audit_lock
    trap audit_unlock RETURN

    prev_hash=$(audit_last_hash) || {
        echo "ERROR: cannot append audit entry after malformed log tail" >&2
        audit_unlock
        trap - RETURN
        return 1
    }
    line=$(
        python3 - "$op" "$path" "$token_id" "$extra_json" "$prev_hash" "${NODE_ID:-unknown}" "$AUDIT_HMAC_KEY_HEX" <<'PY'
import datetime
import hashlib
import hmac
import json
import sys

op, path, token_id, extra_json, prev_hash, node_id, key_hex = sys.argv[1:8]

try:
    extra = json.loads(extra_json or "{}")
except json.JSONDecodeError as exc:
    raise SystemExit(f"invalid audit extra JSON: {exc}")

if not isinstance(extra, dict):
    raise SystemExit("invalid audit extra JSON: expected object")

entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "token_id": token_id,
    "op": op,
    "path": path,
    "version": str(extra.pop("version", "")),
    "lease_id": str(extra.pop("lease_id", "")),
    "node_id": node_id,
    "prev_hash": prev_hash,
}
for reserved in (
    "ts",
    "token_id",
    "op",
    "path",
    "node_id",
    "prev_hash",
    "entry_hash",
    "hmac",
):
    extra.pop(reserved, None)
entry.update(extra)

canonical = json.dumps(entry, sort_keys=True, separators=(",", ":"))
entry_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
key = bytes.fromhex(key_hex)
entry["entry_hash"] = entry_hash
entry["hmac"] = hmac.new(key, entry_hash.encode("ascii"), hashlib.sha256).hexdigest()

print(json.dumps(entry, sort_keys=True, separators=(",", ":")))
PY
    ) || {
        audit_unlock
        trap - RETURN
        return 1
    }

    printf '%s\n' "$line" >> "$AUDIT_LOG"
    audit_unlock
    trap - RETURN
}

audit_query_by_token() {
    local token_id="$1"
    audit_init
    python3 - "$token_id" "$AUDIT_LOG" <<'PY'
import json
import sys

token_id, path = sys.argv[1:3]
matches = []
with open(path, "r", encoding="utf-8") as handle:
    for line in handle:
        if not line.strip():
            continue
        entry = json.loads(line)
        if entry.get("token_id") == token_id:
            matches.append(entry)
print(json.dumps(matches, sort_keys=True, separators=(",", ":")))
PY
}

audit_query_param() {
    local query="$1"
    local key="$2"
    local pair name value

    IFS='&' read -ra pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        name="${pair%%=*}"
        value="${pair#*=}"
        if [[ "$name" == "$key" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

handle_audit_query() {
    local query="$1"
    local request_token="${2:-}"
    local token_filter

    token_filter=$(audit_query_param "$query" "token" || true)
    if [[ -z "$token_filter" ]]; then
        token_filter="$request_token"
    fi

    if [[ -z "$token_filter" ]]; then
        http_respond 400 '{"error":"token query parameter required"}'
        return 0
    fi

    http_respond 200 "$(audit_query_by_token "$token_filter")"
}

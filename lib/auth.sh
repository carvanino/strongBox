#!/usr/bin/env bash
# StrongBox auth, opaque bearer tokens, and policy enforcement.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F storage_get >/dev/null 2>&1; then
    # shellcheck source=lib/storage.sh
    source "$SCRIPT_DIR/storage.sh"
fi

TOKEN_TTL="${TOKEN_TTL:-3600}"
ARGON2_TIME="${ARGON2_TIME:-3}"
ARGON2_MEMORY="${ARGON2_MEMORY:-65536}"
ARGON2_PARALLELISM="${ARGON2_PARALLELISM:-1}"

auth_init() {
    storage_init
}

_generate_token() {
    openssl rand -hex 32
}

_generate_salt() {
    openssl rand -hex 16
}

_now() {
    date +%s
}

_log2_mem() {
    python3 -c "import math; print(int(math.log2(${ARGON2_MEMORY})))"
}

_hash_password() {
    local password="$1"
    local salt
    salt=$(_generate_salt)
    printf '%s' "$password" | argon2 "$salt" -id \
        -t "$ARGON2_TIME" \
        -m "$(_log2_mem)" \
        -p "$ARGON2_PARALLELISM" \
        -l 32 \
        -e
}

_verify_password() {
    local password="$1"
    local stored_hash="$2"
    python3 - "$password" "$stored_hash" <<'PY'
import sys

password, stored_hash = sys.argv[1:3]
try:
    from argon2 import PasswordHasher
    PasswordHasher().verify(stored_hash, password)
except Exception:
    raise SystemExit(1)
PY
}

_json_array_contains() {
    local json="$1"
    local value="$2"
    python3 -c 'import json,sys; raw,value=sys.argv[1:3];
try:
 data=json.loads(raw)
except Exception:
 data=[]
print("true" if value in data else "false")' "$json" "$value"
}

_token_has_root_policy() {
    local token="$1"
    local policies
    policies=$(storage_get "token:${token}:policies" 2>/dev/null || echo "[]")
    [[ "$(_json_array_contains "$policies" root)" == "true" ]]
}

_token_expired() {
    local token="$1"
    local created_at

    _token_has_root_policy "$token" && return 1
    created_at=$(storage_get "token:${token}:created_at" 2>/dev/null) || return 0
    [[ $(( $(_now) - created_at )) -ge "$TOKEN_TTL" ]]
}

auth_create_user() {
    local username="$1"
    local password="$2"
    local policies_json="${3:-[]}"
    local hash

    [[ -z "$username" || -z "$password" ]] && return 1
    printf '%s' "$policies_json" | python3 -m json.tool >/dev/null 2>&1 || return 1

    hash=$(_hash_password "$password") || return 1
    storage_put "user:${username}:hash" "$hash"
    storage_put "user:${username}:policies" "$policies_json"
}

auth_login() {
    local username="$1"
    local password="$2"
    local hash policies token

    hash=$(storage_get "user:${username}:hash" 2>/dev/null) || {
        echo "FAIL"
        return 1
    }

    if ! _verify_password "$password" "$hash"; then
        echo "FAIL"
        return 1
    fi

    policies=$(storage_get "user:${username}:policies" 2>/dev/null || echo "[]")
    token=$(_generate_token)
    storage_put "token:${token}:valid" "true"
    storage_put "token:${token}:policies" "$policies"
    storage_put "token:${token}:created_at" "$(_now)"
    storage_put "token:${token}:username" "$username"
    echo "$token"
}

auth_verify_token() {
    local token="$1"
    local valid policies

    [[ -z "$token" ]] && {
        echo "INVALID"
        return 1
    }

    valid=$(storage_get "token:${token}:valid" 2>/dev/null) || {
        echo "INVALID"
        return 1
    }
    [[ "$valid" != "true" ]] && {
        echo "INVALID"
        return 1
    }

    if _token_expired "$token"; then
        storage_put "token:${token}:valid" "false"
        echo "INVALID"
        return 1
    fi

    policies=$(storage_get "token:${token}:policies" 2>/dev/null || echo "[]")
    echo "$policies"
}

auth_revoke_token() {
    local token="$1"
    storage_put "token:${token}:valid" "false"
}

auth_get_self() {
    local token="$1"
    local policies username created_at ttl age

    policies=$(auth_verify_token "$token")
    if [[ "$policies" == "INVALID" ]]; then
        echo '{"error":"invalid token"}'
        return 1
    fi

    username=$(storage_get "token:${token}:username" 2>/dev/null || echo "")
    created_at=$(storage_get "token:${token}:created_at" 2>/dev/null || echo "$(_now)")

    if _token_has_root_policy "$token"; then
        ttl=0
    else
        age=$(( $(_now) - created_at ))
        ttl=$(( TOKEN_TTL - age ))
        [[ "$ttl" -lt 0 ]] && ttl=0
    fi

    printf '{"token_id":"%s","username":"%s","policies":%s,"ttl":%d}\n' \
        "${token:0:8}" "$username" "$policies" "$ttl"
}

policy_put() {
    local name="$1"
    local rules_json="$2"

    printf '%s' "$rules_json" | python3 -m json.tool >/dev/null 2>&1 || return 1
    storage_put "policy:${name}:rules" "$rules_json"
}

policy_get() {
    local name="$1"
    storage_get "policy:${name}:rules" 2>/dev/null || echo "null"
}

_auth_normalize_path() {
    local path="$1"
    path="${path#/}"
    path="${path#v1/}"
    case "$path" in
        secrets/*) path="secret/${path#secrets/}" ;;
    esac
    printf '%s\n' "$path"
}

auth_check_policy() {
    local token="$1"
    local path="$2"
    local capability="$3"
    local policies request_path policy rules allowed

    policies=$(auth_verify_token "$token")
    if [[ "$policies" == "INVALID" ]]; then
        echo "DENY"
        return 1
    fi

    if _token_has_root_policy "$token"; then
        echo "ALLOW"
        return 0
    fi

    request_path=$(_auth_normalize_path "$path")

    local policy_list
    policy_list=$(python3 -c 'import json,sys; print(" ".join(str(x) for x in json.loads(sys.argv[1])))' "$policies" 2>/dev/null || true)

    for policy in $policy_list; do
        policy="${policy//$'\r'/}"
        [[ -z "$policy" ]] && continue
        rules=$(policy_get "$policy")
        [[ "$rules" == "null" ]] && continue

        allowed=$(python3 -c 'import fnmatch,json,sys
rules=json.loads(sys.argv[1])
request_path=sys.argv[2]
capability=sys.argv[3]
for rule in rules:
    rule_path=str(rule.get("path",""))
    caps=rule.get("capabilities",[])
    if capability in caps and fnmatch.fnmatchcase(request_path, rule_path):
        print("ALLOW")
        raise SystemExit(0)
print("DENY")' "$rules" "$request_path" "$capability")
        if [[ "$allowed" == "ALLOW" ]]; then
            echo "ALLOW"
            return 0
        fi
    done

    echo "DENY"
    return 1
}

# ── Public API ───────────────────────────────────────────────────────────────

# auth_init — verify required tools are present at startup.
auth_init() {
    command -v argon2  &>/dev/null || { echo "[auth] argon2 not found"  >&2; return 1; }
    command -v openssl &>/dev/null || { echo "[auth] openssl not found" >&2; return 1; }
    command -v python3 &>/dev/null || { echo "[auth] python3 not found" >&2; return 1; }
}

# auth_create_user <username> <password> <policies_json>
# Creates a user record. The plaintext password is hashed immediately and
# never stored. policies_json is a JSON array e.g. '["read-only"]'.
auth_create_user() {
    local username="$1"
    local password="$2"
    local policies_json="${3:-[]}"

    local hash
    hash=$(_hash_password "$password")
    # Zero the password variable immediately after hashing
    password=""

    storage_put "user:${username}:hash"     "$hash"
    storage_put "user:${username}:policies" "$policies_json"
}

# auth_login <username> <password>
# On success: prints the raw opaque token to stdout.
# On failure: prints "FAIL" and returns 1.
auth_login() {
    local username="$1"
    local password="$2"

    # Load stored hash — user must exist
    local stored_hash
    stored_hash=$(storage_get "user:${username}:hash" 2>/dev/null) || {
        password=""
        echo "FAIL"
        return 1
    }

    # Verify password — returns 0 on match, 1 on mismatch
    if ! _verify_password "$password" "$stored_hash"; then
        password=""
        echo "FAIL"
        return 1
    fi
    password=""

    local policies
    policies=$(storage_get "user:${username}:policies" 2>/dev/null) || policies='[]'

    # Generate opaque token — all state stored server-side
    local token
    token=$(_generate_token)

    storage_put "token:${token}:valid"      "true"
    storage_put "token:${token}:policies"   "$policies"
    storage_put "token:${token}:created_at" "$(_now)"
    storage_put "token:${token}:username"   "$username"

    echo "$token"
}

# auth_verify_token <token>
# Prints the policies JSON array if the token is valid and not expired.
# Prints "INVALID" if revoked, expired, or unknown.
# This is called on EVERY authenticated request — no caching, always fresh.
auth_verify_token() {
    local token="$1"

    local valid
    valid=$(storage_get "token:${token}:valid" 2>/dev/null) || {
        echo "INVALID"
        return 1
    }

    if [[ "$valid" != "true" ]]; then
        echo "INVALID"
        return 1
    fi

    # Lazy expiry check — mark invalid on first access after TTL
    if _token_expired "$token"; then
        storage_put "token:${token}:valid" "false"
        echo "INVALID"
        return 1
    fi

    storage_get "token:${token}:policies" 2>/dev/null || echo '[]'
}

# auth_revoke_token <token>
# Synchronously invalidates the token.
# The very next request using this token returns 401 — no grace period.
auth_revoke_token() {
    local token="$1"
    storage_put "token:${token}:valid" "false"
}

# auth_get_self <token>
# Prints a JSON object with token metadata.
auth_get_self() {
    local token="$1"

    local policies
    policies=$(auth_verify_token "$token")
    if [[ "$policies" == "INVALID" ]]; then
        echo '{"error":"invalid token"}'
        return 1
    fi

    local created_at username now ttl_remaining
    created_at=$(storage_get "token:${token}:created_at" 2>/dev/null) || created_at=0
    username=$(storage_get   "token:${token}:username"   2>/dev/null) || username="unknown"
    now=$(_now)
    ttl_remaining=$(( TOKEN_TTL - (now - created_at) ))
    [[ $ttl_remaining -lt 0 ]] && ttl_remaining=0

    # token_id shows only first 8 chars — never log the full token
    printf '{"token_id":"%s","username":"%s","policies":%s,"ttl":%d}\n' \
        "${token:0:8}..." "$username" "$policies" "$ttl_remaining"
}

# ── Policy management ──────────────────────────────────────────────────────────

# policy_put <name> <rules_json>
# Stores a named policy. rules_json is an array of rule objects:
# [{"path":"secret/app/*","capabilities":["read","write"]},...]'
policy_put() {
    local name="$1"
    local rules_json="$2"
    storage_put "policy:${name}:rules" "$rules_json"
}

# policy_get <name>
# Prints the rules JSON for a named policy, or "null" if not found.
policy_get() {
    local name="$1"
    storage_get "policy:${name}:rules" 2>/dev/null || {
        echo "null"
        return 1
    }
}

# ── Policy enforcement ──────────────────────────────────────────────────────

# auth_check_policy <token> <path> <capability>
# Called on every authenticated request by the HTTP middleware.
# Prints "ALLOW" or "DENY".
# capability is one of: read, write, delete
auth_check_policy() {
    local token="$1"
    local request_path="$2"
    local capability="$3"

    # Verify token first — returns INVALID if revoked/expired
    local policies_json
    policies_json=$(auth_verify_token "$token")
    if [[ "$policies_json" == "INVALID" ]]; then
        echo "DENY"
        return 1
    fi

    # Root policy bypasses all path checks
    if echo "$policies_json" | grep -q '"root"'; then
        echo "ALLOW"
        return 0
    fi

    # Extract policy names from JSON array and check each one
    local policy_names
    policy_names=$(python3 -c "
import json, sys
try:
    [print(n) for n in json.loads('${policies_json}')]
except: pass
" 2>/dev/null)

    while IFS= read -r pname; do
        [[ -z "$pname" ]] && continue

        local rules
        rules=$(policy_get "$pname") || continue
        [[ "$rules" == "null" ]] && continue

        # Use Python to check path prefix + capability match
        # Supports exact match and wildcard /* suffix
        if python3 - "$rules" "$request_path" "$capability" <<'PYEOF'
import json, sys
rules, path, cap = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
for r in rules:
    pp   = r.get("path", "")
    caps = r.get("capabilities", [])
    matched = (path == pp) or \
              (pp.endswith("/*") and \
               (path.startswith(pp[:-2] + "/") or path == pp[:-2]))
    if matched and cap in caps:
        sys.exit(0)
sys.exit(1)
PYEOF
        then
            echo "ALLOW"
            return 0
        fi
    done <<< "$policy_names"

    echo "DENY"
    return 1
}

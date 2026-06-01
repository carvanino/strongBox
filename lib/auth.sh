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

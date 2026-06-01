#!/bin/bash
# =============================================================================
# lib/auth.sh — Bearer tokens, Argon2id password hashing, policy enforcement

# ── Config ────────────────────────────────────────────────────────────────────
# All thresholds come from environment variables injected by config.yaml.
# Defaults shown here are used when the variable is not set.

TOKEN_TTL="${TOKEN_TTL:-3600}"            # seconds before a token expires
ARGON2_TIME="${ARGON2_TIME:-3}"           # Argon2id: number of iterations
ARGON2_MEMORY="${ARGON2_MEMORY:-65536}"   # Argon2id: memory in KB (64 MB)
ARGON2_PARALLELISM="${ARGON2_PARALLELISM:-1}" # Argon2id: parallel threads

# ── Storage key layout ────────────────────────────────────────────────────────
# user:<username>:hash        → Argon2id encoded hash of the password
# user:<username>:policies    → JSON array of policy names e.g. ["ops","read-only"]
# token:<token>:valid         → "true" or "false"
# token:<token>:policies      → JSON array of policy names
# token:<token>:created_at    → unix timestamp (seconds)
# token:<token>:username      → the user who obtained this token
# policy:<name>:rules         → JSON array of rule objects

# ── Private helpers ───────────────────────────────────────────────────────────

# Generate a 32-byte (64 hex char) cryptographically random opaque token.
# "Opaque" means the token string itself encodes nothing — all state lives
# server-side in storage. This is what enables synchronous revocation.
_generate_token() {
    openssl rand -hex 32
}

# Generate a 16-byte random salt for Argon2id.
_generate_salt() {
    openssl rand -hex 16
}

# Current unix timestamp in seconds.
_now() {
    date +%s
}

# Compute log2 of ARGON2_MEMORY for the argon2 CLI -m flag.
# The argon2 CLI takes memory as a power-of-2 exponent, not raw KB.
# e.g. 65536 KB = 2^16 → -m 16
_log2_mem() {
    python3 -c "import math; print(int(math.log2(${ARGON2_MEMORY})))"
}

# Hash a password with Argon2id. Prints the full encoded hash string.
# The encoded string embeds the salt and parameters, so it is self-contained
# for future verification — we store this string and nothing else.
#
# Command breakdown:
#   printf '%s' "$password"   → password bytes, no trailing newline
#   | argon2 <salt>           → salt passed as positional argument
#   -id                       → use Argon2id variant (hybrid: GPU + side-channel resistant)
#   -t $ARGON2_TIME           → number of iterations (time cost)
#   -m $(_log2_mem)           → memory as log2(KB): -m 16 = 64 MB
#   -p $ARGON2_PARALLELISM    → parallel threads
#   -l 32                     → output hash length: 32 bytes = 256 bits
#   -e                        → output only the encoded hash string (no extra text)
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

# Verify a plaintext password against a stored Argon2id encoded hash.
# Returns 0 if they match, 1 if they do not.
# We use Python argon2-cffi because it can verify against the full encoded
# hash string (which embeds the salt) — the argon2 CLI cannot do this
# reliably without re-parsing the hash manually.
_verify_password() {
    local password="$1"
    local stored_hash="$2"
    python3 - <<PYEOF
import sys
try:
    from argon2 import PasswordHasher
    PasswordHasher().verify("${stored_hash}", "${password}")
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
}

# Return 0 (true) if the token has lived longer than TOKEN_TTL seconds.
_token_expired() {
    local token="$1"
    local created_at
    created_at=$(storage_get "token:${token}:created_at" 2>/dev/null) || return 0
    local age=$(( $(_now) - created_at ))
    [[ $age -ge $TOKEN_TTL ]]
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

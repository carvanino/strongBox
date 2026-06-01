#!/bin/bash
# =============================================================================
# lib/auth.sh — Bearer tokens, Argon2id password hashing, policy enforcement
#
# Public interface:
#   auth_init
#   auth_create_user <username> <password> <policies_json>
#   auth_login       <username> <password>       → token or "FAIL"
#   auth_verify_token <token>                    → policies JSON or "INVALID"
#   auth_revoke_token <token>                    → 0 on success
#   auth_get_self     <token>                    → JSON {token_id,policies,ttl}
#   auth_check_policy <token> <path> <cap>       → "ALLOW" or "DENY"
#   policy_put <name> <rules_json>               → 0 on success
#   policy_get <name>                            → rules JSON
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/storage.sh"

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

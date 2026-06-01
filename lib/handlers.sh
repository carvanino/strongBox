#!/usr/bin/env bash
# =============================================================================
# lib/handlers.sh — Request handlers for StrongBox API endpoints.
# =============================================================================

# LIB_DIR — path to the lib/ directory.
# Defined here so it's available in ncat subshells that source this file
# without going through bin/strongbox.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure auth functions (including policy_put) are available.
if ! declare -F policy_put >/dev/null 2>&1; then
    # shellcheck source=lib/auth.sh
    source "$LIB_DIR/auth.sh"
fi

# RAM-backed directory for unseal shares and KEK
RUN_DIR="${RUN_DIR:-/dev/shm/strongbox}"
if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
    RUN_DIR="/tmp/strongbox-run"
    mkdir -p "$RUN_DIR"
fi

# Helper to replicate system operations (init, unseal, seal) to peers
sys_replicate_to_peers() {
    local method="$1"
    local path_with_query="$2"
    local body="$3"

    local peer peer_id peer_addr
    IFS=',' read -ra peer_items <<< "${PEERS:-}"
    for peer in "${peer_items[@]}"; do
        [[ -z "$peer" ]] && continue
        peer_id="${peer%%=*}"
        peer_addr="${peer#*=}"
        curl -fsS --max-time 2 \
            -X "$method" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$peer_addr$path_with_query" >/dev/null 2>&1 || true
    done
}

# POST /v1/sys/init
# One-time initialisation. Generates master key, splits into Shamir shares,
# creates root token. Returns shares + root_token.
handle_sys_init() {
    local body="$1"
    local query="${2:-}"

    # If it's a replicated request from another node
    if [[ "$query" == *"replicated=true"* ]]; then
        local root_token shares_total shares_required
        root_token=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('root_token',''))" 2>/dev/null)
        shares_total=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('shares_total',''))" 2>/dev/null)
        shares_required=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('shares_required',''))" 2>/dev/null)

        storage_put "sys:initialized" "true"
        storage_put "sys:shamir_k" "$shares_required"
        storage_put "sys:shares_required" "$shares_required"
        storage_put "sys:shamir_n" "$shares_total"
        storage_put "sys:shares_total" "$shares_total"
        storage_put "sys:secret_len" "32"

        storage_put "token:${root_token}:valid"      "true"
        storage_put "token:${root_token}:policies"   '["root"]'
        storage_put "token:${root_token}:created_at" "$(date +%s)"
        storage_put "token:${root_token}:username"   "root"

        policy_put "root" '[{"path":"*","capabilities":["read","write","delete"]}]'

        http_respond 201 '{"status":"initialized"}'
        return
    fi

    # Cannot init twice
    if storage_get "sys:initialized" &>/dev/null; then
        http_respond 400 '{"error":"already initialized"}'
        return
    fi

    # Parse optional N and K from request body.
    # secret_shares is the total number of shares; secret_threshold is how many are required.
    local shares_total shares_required
    shares_total=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read() or '{}'); print(d.get('secret_shares',${SHAMIR_N:-3}))" 2>/dev/null) || shares_total=${SHAMIR_N:-3}
    shares_required=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read() or '{}'); print(d.get('secret_threshold',${SHAMIR_K:-2}))" 2>/dev/null) || shares_required=${SHAMIR_K:-2}

    if ! [[ "$shares_total" =~ ^[0-9]+$ && "$shares_required" =~ ^[0-9]+$ ]] || [[ "$shares_required" -lt 1 || "$shares_total" -lt "$shares_required" ]]; then
        http_respond 400 '{"error":"invalid Shamir parameters"}'
        return
    fi

    # Generate master key (KEK) — 32 random bytes
    local master_key
    master_key=$(openssl rand -hex 32)

    # Split master key into N Shamir shares, requiring K to reconstruct
    local shares_json
    shares_json=$(python3 "$LIB_DIR/shamir.py" split "$master_key" "$shares_total" "$shares_required")

    # Extract share strings for the response
    local share_strings
    share_strings=$(python3 -c "
import json, sys
shares = json.loads(sys.argv[1])
result = ['{},{}'.format(s['x'], s['y']) for s in shares]
print(json.dumps(result))
" "$shares_json")

    # Store init state
    storage_put "sys:initialized" "true"
    storage_put "sys:shamir_k" "$shares_required"
    storage_put "sys:shares_required" "$shares_required"
    storage_put "sys:shamir_n" "$shares_total"
    storage_put "sys:shares_total" "$shares_total"
    storage_put "sys:secret_len" "32"

    # Create root token — full access, no expiry
    local root_token
    root_token=$(openssl rand -hex 32)
    storage_put "token:${root_token}:valid"      "true"
    storage_put "token:${root_token}:policies"   '["root"]'
    storage_put "token:${root_token}:created_at" "$(date +%s)"
    storage_put "token:${root_token}:username"   "root"

    # Store root policy
    policy_put "root" '[{"path":"*","capabilities":["read","write","delete"]}]'

    # Zero master key variable
    master_key=""

    # Replicate init to peers
    local peer_payload
    peer_payload=$(printf '{"root_token":"%s","shares_total":%d,"shares_required":%d}' "$root_token" "$shares_total" "$shares_required")
    sys_replicate_to_peers "POST" "/v1/sys/init?replicated=true" "$peer_payload"

    # Audit the init event
    audit_append "sys.init" "/v1/sys/init" "root" "{}" 2>/dev/null || true

    http_respond 201 "{\"shares\":${share_strings},\"root_token\":\"${root_token}\"}"
}

# POST /v1/sys/unseal {share}
# Accumulates shares. Once K shares collected, reconstructs master key,
# loads KEK into memory, transitions to unsealed.
handle_sys_unseal() {
    local body="$1"
    local query="${2:-}"

    local share
    share=$(printf '%s' "$body" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print(d.get('share', ''))
" 2>/dev/null)

    if [[ -z "$share" ]]; then
        http_respond 400 '{"error":"share is required"}'
        return
    fi

    # Replicate to peers if not already replicated
    if [[ "$query" != *"replicated=true"* ]]; then
        sys_replicate_to_peers "POST" "/v1/sys/unseal?replicated=true" "$body"
    fi

    # Save to RAM-backed shares file
    mkdir -p "$RUN_DIR"
    if [[ -f "$RUN_DIR/shares" ]]; then
        if ! grep -qxF "$share" "$RUN_DIR/shares"; then
            echo "$share" >> "$RUN_DIR/shares"
        fi
    else
        echo "$share" > "$RUN_DIR/shares"
    fi

    local k
    k=$(storage_get "sys:shares_required" 2>/dev/null) || k=${SHAMIR_K:-2}

    local collected_shares=()
    if [[ -f "$RUN_DIR/shares" ]]; then
        mapfile -t collected_shares < "$RUN_DIR/shares"
    fi
    local collected=${#collected_shares[@]}

    if [[ $collected -lt $k ]]; then
        # Not enough shares yet (vault remains sealed)
        touch "$SEALED_FILE"
        http_respond 200 "{\"sealed\":true,\"progress\":\"${collected}/${k}\"}"
        return
    fi

    # Have K shares — reconstruct master key
    local secret_len
    secret_len=$(storage_get "sys:secret_len" 2>/dev/null) || secret_len=32

    # Build shares JSON array for shamir.py
    local shares_json
    shares_json=$(python3 -c "
import sys, json
shares = []
for s in sys.argv[1:]:
    x, y = s.split(',', 1)
    shares.append({'x': int(x), 'y': y})
print(json.dumps(shares))
" "${collected_shares[@]}")

    local master_key
    master_key=$(python3 "$LIB_DIR/shamir.py" reconstruct "$shares_json" "$secret_len" 2>/dev/null)

    if [[ -z "$master_key" ]]; then
        http_respond 400 '{"error":"share reconstruction failed — invalid or insufficient shares"}'
        # Clear RAM shares
        if [[ -f "$RUN_DIR/shares" ]]; then
            dd if=/dev/zero of="$RUN_DIR/shares" bs=1 count=128 conv=notrunc 2>/dev/null || true
            rm -f "$RUN_DIR/shares"
        fi
        return
    fi

    # Load KEK into crypto module memory (RAM file)
    crypto_set_kek "$master_key"

    # Zero shares and master key from memory immediately
    if [[ -f "$RUN_DIR/shares" ]]; then
        local size
        size=$(wc -c < "$RUN_DIR/shares" 2>/dev/null || echo 128)
        dd if=/dev/zero of="$RUN_DIR/shares" bs=1 count="$size" conv=notrunc 2>/dev/null || true
        rm -f "$RUN_DIR/shares"
    fi
    master_key=""
    shares_json=""

    # Transition to unsealed
    rm -f "$SEALED_FILE"

    audit_append "sys.unseal" "/v1/sys/unseal" "operator" "{}" 2>/dev/null || true

    http_respond 200 "{\"sealed\":false,\"progress\":\"${k}/${k}\"}"
}

# POST /v1/sys/seal
# Purges the KEK from memory and returns to sealed state.
handle_sys_seal() {
    local token="${1:-}"
    local query="${2:-}"

    # Replicate to peers if not already replicated
    if [[ "$query" != *"replicated=true"* ]]; then
        sys_replicate_to_peers "POST" "/v1/sys/seal?replicated=true" ""
    fi

    crypto_zero_kek
    touch "$SEALED_FILE"
    
    # Zero and delete RAM shares
    if [[ -f "$RUN_DIR/shares" ]]; then
        local size
        size=$(wc -c < "$RUN_DIR/shares" 2>/dev/null || echo 128)
        dd if=/dev/zero of="$RUN_DIR/shares" bs=1 count="$size" conv=notrunc 2>/dev/null || true
        rm -f "$RUN_DIR/shares"
    fi

    audit_append "sys.seal" "/v1/sys/seal" "$token" "{}" 2>/dev/null || true
    http_no_content
}

# PUT /v1/secrets/{path}
handle_secret_put() {
    local secret_path="$1"
    local body="$2"
    local token="$3"

    local encrypted
    encrypted=$(crypto_encrypt_secret "$body") || {
        http_respond 500 '{"error":"encryption failed"}'
        return
    }

    local version
    version=$(storage_put_version "secret:${secret_path}" "$encrypted")

    audit_append "secret.write" "$secret_path" "$token" "{\"version\":$version}" 2>/dev/null || true

    http_respond 201 "{\"version\":$version}"
}

# GET /v1/secrets/{path}[?version=N]
handle_secret_get() {
    local secret_path="$1"
    local query="$2"
    local token="$3"

    local version=""
    if [[ "$query" == *"version="* ]]; then
        version="${query#*version=}"
        version="${version%%&*}"
    fi

    local encrypted
    if [[ -n "$version" ]]; then
        encrypted=$(storage_get_version "secret:${secret_path}" "$version" 2>/dev/null) || {
            http_respond 404 '{"error":"version not found"}'
            return
        }
    else
        encrypted=$(storage_get "secret:${secret_path}" 2>/dev/null) || {
            http_respond 404 '{"error":"secret not found"}'
            return
        }
        version=$(storage_latest_version "secret:${secret_path}")
    fi

    # Decrypt the secret
    local ciphertext nonce wrapped_dek dek_nonce plaintext
    ciphertext=$(printf '%s' "$encrypted"  | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['ciphertext'])")
    nonce=$(printf '%s' "$encrypted"       | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['nonce'])")
    wrapped_dek=$(printf '%s' "$encrypted" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['wrapped_dek'])")
    dek_nonce=$(printf '%s' "$encrypted"   | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['dek_nonce'])")

    plaintext=$(crypto_decrypt_secret "$ciphertext" "$nonce" "$wrapped_dek" "$dek_nonce") || {
        http_respond 500 '{"error":"decryption failed"}'
        return
    }

    # Create a lease for this read
    local lease_id
    lease_id=$(lease_create "$secret_path" "${DEFAULT_LEASE_TTL:-3600}")

    audit_append "secret.read" "$secret_path" "$token" "{\"version\":$version,\"lease_id\":\"$lease_id\"}" 2>/dev/null || true

    http_respond 200 "{\"data\":${plaintext},\"version\":${version},\"lease\":{\"id\":\"${lease_id}\",\"ttl\":${DEFAULT_LEASE_TTL:-3600}}}"
}

# DELETE /v1/secrets/{path}
handle_secret_delete() {
    local secret_path="$1"
    local token="$2"

    storage_delete "secret:${secret_path}" || {
        http_respond 404 '{"error":"secret not found"}'
        return
    }

    audit_append "secret.delete" "$secret_path" "$token" "{}" 2>/dev/null || true
    http_no_content
}

# GET /v1/dynamic-postgres/{role}
handle_dynamic_postgres_get() {
    local role_name="$1"
    local token="$2"

    local grants=""
    local result
    result=$(dynamic_mint_role "$role_name" "$grants") || {
        http_respond 500 '{"error":"failed to mint dynamic credential"}'
        return
    }

    audit_append "dynamic.read" "dynamic-postgres/${role_name}" "$token" "{}" 2>/dev/null || true

    http_respond 200 "$result"
}

# POST /v1/auth/login
handle_auth_login() {
    local body="$1"

    local username password
    username=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('username',''))" 2>/dev/null)
    password=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('password',''))" 2>/dev/null)

    if [[ -z "$username" || -z "$password" ]]; then
        http_respond 400 '{"error":"username and password required"}'
        return
    fi

    local token
    token=$(auth_login "$username" "$password")

    if [[ "$token" == "FAIL" ]]; then
        audit_append "auth.login.fail" "/v1/auth/login" "anonymous" "{\"username\":\"$username\"}" 2>/dev/null || true
        http_respond 401 '{"error":"invalid credentials"}'
        return
    fi

    local policies
    policies=$(storage_get "token:${token}:policies" 2>/dev/null) || policies='[]'

    audit_append "auth.login" "/v1/auth/login" "${token:0:8}" "{\"username\":\"$username\"}" 2>/dev/null || true

    http_respond 200 "{\"token\":\"${token}\",\"policies\":${policies}}"
}

# POST /v1/auth/revoke
handle_auth_revoke() {
    local body="$1"
    local requesting_token="${2:-}"

    local target_token
    target_token=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('token',''))" 2>/dev/null)

    if [[ -z "$target_token" ]]; then
        http_respond 400 '{"error":"token required"}'
        return
    fi

    # Synchronous revocation — next request with this token returns 401 immediately
    auth_revoke_token "$target_token"

    audit_append "auth.revoke" "/v1/auth/revoke" "$requesting_token" "{}" 2>/dev/null || true
    http_no_content
}

# GET /v1/auth/self
handle_auth_self() {
    local token="$1"
    local result
    result=$(auth_get_self "$token")
    http_respond 200 "$result"
}

# PUT /v1/users/{username}
handle_user_put() {
    local username="$1"
    local body="$2"
    local token="$3"

    local password policies
    password=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('password',''))" 2>/dev/null)
    policies=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(json.dumps(d.get('policies',[])))" 2>/dev/null)

    if [[ -z "$username" || -z "$password" ]]; then
        http_respond 400 '{"error":"username and password required"}'
        return
    fi

    auth_create_user "$username" "$password" "$policies" || {
        http_respond 400 '{"error":"failed to create user"}'
        return
    }

    audit_append "auth.user.create" "/v1/users/${username}" "$token" "{\"username\":\"$username\"}" 2>/dev/null || true
    http_respond 201 "{\"username\":\"${username}\",\"policies\":${policies}}"
}

# PUT /v1/policies/{name}
handle_policy_put() {
    local policy_name="$1"
    local body="$2"
    local token="$3"

    local rules
    rules=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(json.dumps(d.get('rules',[])))" 2>/dev/null)

    policy_put "$policy_name" "$rules"

    audit_append "policy.write" "/v1/policies/${policy_name}" "$token" "{}" 2>/dev/null || true
    http_respond 201 "{\"name\":\"${policy_name}\",\"rules\":${rules}}"
}

# GET /v1/policies/{name}
handle_policy_get() {
    local policy_name="$1"
    local token="$2"

    local rules
    rules=$(policy_get "$policy_name")

    if [[ "$rules" == "null" ]]; then
        http_respond 404 '{"error":"policy not found"}'
        return
    fi

    http_respond 200 "{\"rules\":${rules}}"
}

# POST /v1/leases/{id}/renew
handle_lease_renew() {
    local lease_id="$1"
    local token="$2"

    local new_ttl
    new_ttl=$(lease_renew "$lease_id")

    if [[ "$new_ttl" == "FAIL" ]]; then
        http_respond 400 '{"error":"lease cannot be renewed (expired or at max TTL)"}'
        return
    fi

    audit_append "lease.renew" "/v1/leases/${lease_id}/renew" "$token" "{\"lease_id\":\"$lease_id\"}" 2>/dev/null || true
    http_respond 200 "{\"new_ttl\":${new_ttl}}"
}

# POST /v1/leases/{id}/revoke
handle_lease_revoke() {
    local lease_id="$1"
    local token="$2"

    lease_revoke "$lease_id"

    audit_append "lease.revoke" "/v1/leases/${lease_id}/revoke" "$token" "{\"lease_id\":\"$lease_id\"}" 2>/dev/null || true
    http_no_content
}

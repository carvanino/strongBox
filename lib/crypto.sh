#!/bin/bash
# Envelope encryption for StrongBox
# Every secret gets its own DEK (data encryption key)
# DEK is wrapped by the KEK (master key) that lives only in memory

# Global KEK - lives in memory only, never written to disk
STRONGBOX_KEK=""

crypto_set_kek() {
    STRONGBOX_KEK="$1"
}

crypto_get_kek() {
    echo "$STRONGBOX_KEK"
}

crypto_zero_kek() {
    STRONGBOX_KEK=""
}

crypto_generate_key() {
    openssl rand -hex 32
}

crypto_generate_nonce() {
    openssl rand -hex 12
}

crypto_encrypt_aes_gcm() {
    local key_hex="$1"
    local nonce_hex="$2"
    local plaintext="$3"

    echo -n "$plaintext" | openssl enc -aes-256-gcm \
        -K "$key_hex" \
        -iv "$nonce_hex" \
        -nosalt \
        -a 2>/dev/null | tr -d '\n'
}

crypto_decrypt_aes_gcm() {
    local key_hex="$1"
    local nonce_hex="$2"
    local ciphertext_b64="$3"

    echo "$ciphertext_b64" | openssl enc -aes-256-gcm \
        -d \
        -K "$key_hex" \
        -iv "$nonce_hex" \
        -nosalt \
        -a 2>/dev/null
}

crypto_wrap_dek() {
    local dek_hex="$1"
    local kek="$STRONGBOX_KEK"

    if [[ -z "$kek" ]]; then
        echo '{"error":"vault is sealed"}' >&2
        return 1
    fi

    local nonce
    nonce=$(crypto_generate_nonce)
    local wrapped
    wrapped=$(crypto_encrypt_aes_gcm "$kek" "$nonce" "$dek_hex")

    echo "{\"wrapped_dek\":\"$wrapped\",\"nonce\":\"$nonce\"}"
}

crypto_unwrap_dek() {
    local wrapped_dek="$1"
    local nonce="$2"
    local kek="$STRONGBOX_KEK"

    if [[ -z "$kek" ]]; then
        echo "vault is sealed" >&2
        return 1
    fi

    crypto_decrypt_aes_gcm "$kek" "$nonce" "$wrapped_dek"
}

crypto_encrypt_secret() {
    local plaintext="$1"

    local dek
    dek=$(crypto_generate_key)
    local nonce
    nonce=$(crypto_generate_nonce)

    local ciphertext
    ciphertext=$(crypto_encrypt_aes_gcm "$dek" "$nonce" "$plaintext")

    local wrap_result
    wrap_result=$(crypto_wrap_dek "$dek")

    local wrapped_dek dek_nonce
    wrapped_dek=$(echo "$wrap_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['wrapped_dek'])")
    dek_nonce=$(echo "$wrap_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['nonce'])")

    dek=""

    echo "{\"ciphertext\":\"$ciphertext\",\"nonce\":\"$nonce\",\"wrapped_dek\":\"$wrapped_dek\",\"dek_nonce\":\"$dek_nonce\"}"
}

crypto_decrypt_secret() {
    local ciphertext="$1"
    local nonce="$2"
    local wrapped_dek="$3"
    local dek_nonce="$4"

    local dek
    dek=$(crypto_unwrap_dek "$wrapped_dek" "$dek_nonce") || return 1

    local plaintext
    plaintext=$(crypto_decrypt_aes_gcm "$dek" "$nonce" "$ciphertext")

    dek=""

    echo "$plaintext"
}

crypto_hmac_sha256() {
    local key_hex="$1"
    local data="$2"

    echo -n "$data" | openssl dgst -sha256 -mac HMAC \
        -macopt "hexkey:$key_hex" | awk '{print $2}'
}

crypto_hash_password() {
    echo -n "$1" | argon2 "$(openssl rand -hex 16)" -id -t 3 -m 16 -p 2 -l 32 -e
}

crypto_verify_password() {
    local password="$1"
    local hash="$2"

    echo "$hash" | argon2 "$(echo "$hash" | cut -d'$' -f3)" \
        -id -t 3 -m 16 -p 2 -l 32 -e > /dev/null 2>&1
}

#!/bin/bash
# Envelope encryption for StrongBox
# Every secret gets its own DEK (data encryption key)
# DEK is wrapped by the KEK (master key) that lives only in memory

# Store KEK and unseal shares in a RAM-backed (tmpfs) directory so that they persist
# across the independent bash processes spawned by ncat for each TCP connection,
# while remaining purely in-memory (volatile RAM) as required.
RUN_DIR="/dev/shm/strongbox"
if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
    RUN_DIR="/tmp/strongbox-run"
    mkdir -p "$RUN_DIR"
fi

crypto_set_kek() {
    mkdir -p "$RUN_DIR"
    echo -n "$1" > "$RUN_DIR/kek"
}

crypto_get_kek() {
    if [[ -f "$RUN_DIR/kek" ]]; then
        cat "$RUN_DIR/kek"
    fi
}

crypto_zero_kek() {
    if [[ -f "$RUN_DIR/kek" ]]; then
        local size
        size=$(wc -c < "$RUN_DIR/kek" 2>/dev/null || echo 64)
        dd if=/dev/zero of="$RUN_DIR/kek" bs=1 count="$size" conv=notrunc 2>/dev/null || true
        rm -f "$RUN_DIR/kek"
    fi
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
    local plaintext_b64

    plaintext_b64=$(printf '%s' "$plaintext" | openssl base64 -A)

    python3 - "$key_hex" "$nonce_hex" "$plaintext_b64" <<'PY'
import base64
import ctypes
import ctypes.util
import os
import sys

EVP_CTRL_GCM_SET_IVLEN = 0x9
EVP_CTRL_GCM_GET_TAG = 0x10
TAG_LEN = 16

key_hex, nonce_hex, plaintext_b64 = sys.argv[1:4]
key = bytes.fromhex(key_hex)
nonce = bytes.fromhex(nonce_hex)
plaintext = base64.b64decode(plaintext_b64)

if len(key) != 32:
    raise SystemExit("AES-256-GCM key must be 32 bytes")
if len(nonce) != 12:
    raise SystemExit("AES-GCM nonce must be 12 bytes")

def load_libcrypto():
    candidates = [
        ctypes.util.find_library("crypto"),
        os.environ.get("STRONGBOX_LIBCRYPTO"),
        "libcrypto.so.3",
        "libcrypto.so",
        "libcrypto-3-x64.dll",
        "/usr/lib/x86_64-linux-gnu/libcrypto.so.3",
        "/usr/lib64/libcrypto.so.3",
        "/mingw64/bin/libcrypto-3-x64.dll",
        "/usr/bin/libcrypto-3-x64.dll",
        r"C:\Program Files\Git\mingw64\bin\libcrypto-3-x64.dll",
    ]
    for item in candidates:
        if not item:
            continue
        try:
            return ctypes.CDLL(item)
        except OSError:
            continue
    raise SystemExit("unable to load OpenSSL libcrypto")

lib = load_libcrypto()
lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
lib.EVP_aes_256_gcm.restype = ctypes.c_void_p
lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]
lib.EVP_EncryptInit_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lib.EVP_EncryptInit_ex.restype = ctypes.c_int
lib.EVP_EncryptUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.c_void_p, ctypes.c_int]
lib.EVP_EncryptUpdate.restype = ctypes.c_int
lib.EVP_EncryptFinal_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
lib.EVP_EncryptFinal_ex.restype = ctypes.c_int
lib.EVP_CIPHER_CTX_ctrl.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.EVP_CIPHER_CTX_ctrl.restype = ctypes.c_int

ctx = lib.EVP_CIPHER_CTX_new()
if not ctx:
    raise SystemExit("EVP_CIPHER_CTX_new failed")

try:
    if lib.EVP_EncryptInit_ex(ctx, lib.EVP_aes_256_gcm(), None, None, None) != 1:
        raise SystemExit("EVP_EncryptInit_ex failed")
    if lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, len(nonce), None) != 1:
        raise SystemExit("EVP_CIPHER_CTX_ctrl SET_IVLEN failed")
    if lib.EVP_EncryptInit_ex(ctx, None, None, key, nonce) != 1:
        raise SystemExit("EVP_EncryptInit_ex key/iv failed")

    inbuf = ctypes.create_string_buffer(plaintext)
    out = ctypes.create_string_buffer(len(plaintext) + 16)
    out_len = ctypes.c_int(0)
    if lib.EVP_EncryptUpdate(ctx, out, ctypes.byref(out_len), inbuf, len(plaintext)) != 1:
        raise SystemExit("EVP_EncryptUpdate failed")
    total = out_len.value

    final_len = ctypes.c_int(0)
    if lib.EVP_EncryptFinal_ex(ctx, ctypes.byref(out, total), ctypes.byref(final_len)) != 1:
        raise SystemExit("EVP_EncryptFinal_ex failed")
    total += final_len.value

    tag = ctypes.create_string_buffer(TAG_LEN)
    if lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, TAG_LEN, tag) != 1:
        raise SystemExit("EVP_CIPHER_CTX_ctrl GET_TAG failed")

    sys.stdout.write(base64.b64encode(out.raw[:total] + tag.raw).decode("ascii"))
finally:
    lib.EVP_CIPHER_CTX_free(ctx)
PY
}

crypto_decrypt_aes_gcm() {
    local key_hex="$1"
    local nonce_hex="$2"
    local ciphertext_b64="$3"

    python3 - "$key_hex" "$nonce_hex" "$ciphertext_b64" <<'PY'
import base64
import ctypes
import ctypes.util
import os
import sys

EVP_CTRL_GCM_SET_IVLEN = 0x9
EVP_CTRL_GCM_SET_TAG = 0x11
TAG_LEN = 16

key_hex, nonce_hex, ciphertext_b64 = sys.argv[1:4]
key = bytes.fromhex(key_hex)
nonce = bytes.fromhex(nonce_hex)
sealed = base64.b64decode(ciphertext_b64)

if len(key) != 32:
    raise SystemExit("AES-256-GCM key must be 32 bytes")
if len(nonce) != 12:
    raise SystemExit("AES-GCM nonce must be 12 bytes")
if len(sealed) < TAG_LEN:
    raise SystemExit("ciphertext missing GCM tag")

ciphertext = sealed[:-TAG_LEN]
tag = sealed[-TAG_LEN:]

def load_libcrypto():
    candidates = [
        ctypes.util.find_library("crypto"),
        os.environ.get("STRONGBOX_LIBCRYPTO"),
        "libcrypto.so.3",
        "libcrypto.so",
        "libcrypto-3-x64.dll",
        "/usr/lib/x86_64-linux-gnu/libcrypto.so.3",
        "/usr/lib64/libcrypto.so.3",
        "/mingw64/bin/libcrypto-3-x64.dll",
        "/usr/bin/libcrypto-3-x64.dll",
        r"C:\Program Files\Git\mingw64\bin\libcrypto-3-x64.dll",
    ]
    for item in candidates:
        if not item:
            continue
        try:
            return ctypes.CDLL(item)
        except OSError:
            continue
    raise SystemExit("unable to load OpenSSL libcrypto")

lib = load_libcrypto()
lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
lib.EVP_aes_256_gcm.restype = ctypes.c_void_p
lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]
lib.EVP_DecryptInit_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lib.EVP_DecryptInit_ex.restype = ctypes.c_int
lib.EVP_DecryptUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.c_void_p, ctypes.c_int]
lib.EVP_DecryptUpdate.restype = ctypes.c_int
lib.EVP_DecryptFinal_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
lib.EVP_DecryptFinal_ex.restype = ctypes.c_int
lib.EVP_CIPHER_CTX_ctrl.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.EVP_CIPHER_CTX_ctrl.restype = ctypes.c_int

ctx = lib.EVP_CIPHER_CTX_new()
if not ctx:
    raise SystemExit("EVP_CIPHER_CTX_new failed")

try:
    if lib.EVP_DecryptInit_ex(ctx, lib.EVP_aes_256_gcm(), None, None, None) != 1:
        raise SystemExit("EVP_DecryptInit_ex failed")
    if lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, len(nonce), None) != 1:
        raise SystemExit("EVP_CIPHER_CTX_ctrl SET_IVLEN failed")
    if lib.EVP_DecryptInit_ex(ctx, None, None, key, nonce) != 1:
        raise SystemExit("EVP_DecryptInit_ex key/iv failed")

    inbuf = ctypes.create_string_buffer(ciphertext)
    out = ctypes.create_string_buffer(len(ciphertext) + 16)
    out_len = ctypes.c_int(0)
    if lib.EVP_DecryptUpdate(ctx, out, ctypes.byref(out_len), inbuf, len(ciphertext)) != 1:
        raise SystemExit("EVP_DecryptUpdate failed")
    total = out_len.value

    tag_buf = ctypes.create_string_buffer(tag, TAG_LEN)
    if lib.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, TAG_LEN, tag_buf) != 1:
        raise SystemExit("EVP_CIPHER_CTX_ctrl SET_TAG failed")

    final_len = ctypes.c_int(0)
    if lib.EVP_DecryptFinal_ex(ctx, ctypes.byref(out, total), ctypes.byref(final_len)) != 1:
        raise SystemExit("AES-GCM authentication failed")
    total += final_len.value

    sys.stdout.buffer.write(out.raw[:total])
finally:
    lib.EVP_CIPHER_CTX_free(ctx)
PY
}

crypto_wrap_dek() {
    local dek_hex="$1"
    local kek
    kek=$(crypto_get_kek)

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
    local kek
    kek=$(crypto_get_kek)

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

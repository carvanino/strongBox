#!/usr/bin/env python3
"""
Shamir's Secret Sharing over GF(2^8).
Used by strongbox for K-of-N master key reconstruction.
Called from Bash via subprocess.
"""
import sys
import os
import json
import secrets

# GF(2^8) arithmetic using AES irreducible polynomial x^8+x^4+x^3+x+1
PRIME = 0x11b

def _gf_add(a, b):
    return a ^ b

def _gf_mul(a, b):
    result = 0
    for _ in range(8):
        if b & 1:
            result ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= (PRIME & 0xFF)
        b >>= 1
    return result

def _gf_pow(base, exp):
    result = 1
    for _ in range(exp):
        result = _gf_mul(result, base)
    return result

def _gf_inv(a):
    if a == 0:
        raise ValueError("Cannot invert zero in GF(2^8)")
    return _gf_pow(a, 254)

def _gf_div(a, b):
    return _gf_mul(a, _gf_inv(b))

def _evaluate_polynomial(coefficients, x):
    result = 0
    x_pow = 1
    for coeff in coefficients:
        result = _gf_add(result, _gf_mul(coeff, x_pow))
        x_pow = _gf_mul(x_pow, x)
    return result

def split_secret(secret_bytes, n, k):
    shares = [[] for _ in range(n)]
    for byte in secret_bytes:
        coefficients = [byte] + [secrets.randbelow(256) for _ in range(k - 1)]
        for i in range(n):
            x = i + 1
            y = _evaluate_polynomial(coefficients, x)
            shares[i].append(y)
    return [(i + 1, bytes(share)) for i, share in enumerate(shares)]

def reconstruct_secret(shares, secret_len):
    result = []
    for byte_idx in range(secret_len):
        points = [(x, y_bytes[byte_idx]) for x, y_bytes in shares]
        secret_byte = 0
        for i, (xi, yi) in enumerate(points):
            numerator = yi
            denominator = 1
            for j, (xj, _) in enumerate(points):
                if i != j:
                    numerator = _gf_mul(numerator, xj)
                    denominator = _gf_mul(denominator, _gf_add(xi, xj))
            secret_byte = _gf_add(secret_byte, _gf_div(numerator, denominator))
        result.append(secret_byte)
    return bytes(result)

def zero_sensitive(data):
    if isinstance(data, bytearray):
        for i in range(len(data)):
            data[i] = 0

if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""

    if command == "split":
        secret_hex = sys.argv[2]
        n = int(sys.argv[3])
        k = int(sys.argv[4])
        secret_bytes = bytes.fromhex(secret_hex)
        shares = split_secret(secret_bytes, n, k)
        output = [{"x": x, "y": y.hex()} for x, y in shares]
        print(json.dumps(output))

    elif command == "reconstruct":
        shares_json = sys.argv[2]
        secret_len = int(sys.argv[3])
        shares_data = json.loads(shares_json)
        shares = [(s["x"], bytes.fromhex(s["y"])) for s in shares_data]
        secret = reconstruct_secret(shares, secret_len)
        print(secret.hex())

    else:
        print("Usage: shamir.py split <hex> <n> <k>", file=sys.stderr)
        print("       shamir.py reconstruct <json> <len>", file=sys.stderr)
        sys.exit(1)

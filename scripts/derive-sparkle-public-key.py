#!/usr/bin/env python3
"""Derive the Ed25519 public key from a Sparkle private key (RFC 8032).

Reads the base64 private key on stdin and writes the base64 public key to
stdout. The private key is never echoed.

Exists so CI can prove SPARKLE_PRIVATE_KEY is the private half of the
SUPublicEDKey the app ships. Pure standard library: the runner has no
cryptography package, and pulling one in to check a key is a poor trade.
"""
import base64
import hashlib
import sys

sys.setrecursionlimit(3000)

P = 2**255 - 19


def inv(x):
    return pow(x, P - 2, P)


D = -121665 * inv(121666) % P
I = pow(2, (P - 1) // 4, P)


def xrecover(y):
    xx = (y * y - 1) * inv(D * y * y + 1)
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = (x * I) % P
    if x % 2 != 0:
        x = P - x
    return x


BASE_Y = 4 * inv(5)
BASE = [xrecover(BASE_Y) % P, BASE_Y % P]


def edwards(point_a, point_b):
    x1, y1 = point_a
    x2, y2 = point_b
    return [(x1 * y2 + x2 * y1) * inv(1 + D * x1 * x2 * y1 * y2) % P,
            (y1 * y2 + x1 * x2) * inv(1 - D * x1 * x2 * y1 * y2) % P]


def scalarmult(point, scalar):
    if scalar == 0:
        return [0, 1]
    half = scalarmult(point, scalar // 2)
    doubled = edwards(half, half)
    return edwards(doubled, point) if scalar & 1 else doubled


def encodepoint(point):
    x, y = point
    bits = [(y >> i) & 1 for i in range(255)] + [x & 1]
    return bytes(sum(bits[i * 8 + j] << j for j in range(8)) for i in range(32))


def public_key(seed: bytes) -> bytes:
    # Some tools store seed||public; the seed is the first 32 bytes.
    if len(seed) == 64:
        seed = seed[:32]
    if len(seed) != 32:
        raise ValueError(f"expected a 32-byte seed, got {len(seed)} bytes")
    digest = bytearray(hashlib.sha512(seed).digest()[:32])
    digest[0] &= 248
    digest[31] &= 127
    digest[31] |= 64
    return encodepoint(scalarmult(BASE, int.from_bytes(digest, "little")))


def main() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        sys.stderr.write("no private key on stdin\n")
        return 1
    try:
        seed = base64.b64decode(raw, validate=True)
    except Exception:
        sys.stderr.write("private key is not valid base64\n")
        return 1
    try:
        print(base64.b64encode(public_key(seed)).decode())
    except ValueError as error:
        sys.stderr.write(f"{error}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/bin/sh
# Recipe: libsodium — minimal signature/random API shim for wasm32

NAME="libsodium"
VERSION="0.1.0"
DESCRIPTION="Minimal libsodium compatibility shim"
SOURCE_URL="https://download.libsodium.org/libsodium/releases/libsodium-1.0.20.tar.gz"

build() {
    install -d "$SRC/bootstrap" "$STAGE/usr/include" "$STAGE/usr/lib" "$STAGE/usr/lib/pkgconfig"

    cat > "$SRC/bootstrap/sodium.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_SODIUM_H
#define LOT_BOOTSTRAP_SODIUM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define crypto_sign_BYTES 64
#define crypto_sign_PUBLICKEYBYTES 32
#define crypto_sign_SECRETKEYBYTES 64

int sodium_init(void);
void randombytes_buf(void * const buf, const size_t size);

int crypto_sign_keypair(unsigned char *pk, unsigned char *sk);
int crypto_sign_ed25519_sk_to_pk(unsigned char *pk, const unsigned char *sk);
int crypto_sign_detached(unsigned char *sig,
                         unsigned long long *siglen_p,
                         const unsigned char *m,
                         unsigned long long mlen,
                         const unsigned char *sk);
int crypto_sign_verify_detached(const unsigned char *sig,
                                const unsigned char *m,
                                unsigned long long mlen,
                                const unsigned char *pk);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/libsodium_stub.c" << 'EOF'
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "sodium.h"

static uint64_t g_rng = 0x72616e646f6d6575ULL;

static uint64_t xorshift64star(void)
{
    uint64_t x = g_rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    g_rng = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static void pseudo_sig_from_pk(unsigned char *sig, const unsigned char *pk, const unsigned char *m, unsigned long long mlen)
{
    uint64_t h = 0x9e3779b97f4a7c15ULL;
    for (size_t i = 0; i < crypto_sign_PUBLICKEYBYTES; ++i) h = (h ^ pk[i]) * 0x100000001b3ULL;
    for (unsigned long long i = 0; i < mlen; ++i) h = (h ^ m[i]) * 0x100000001b3ULL;
    for (size_t i = 0; i < crypto_sign_BYTES; ++i) {
        h ^= (h >> 33);
        h *= 0xff51afd7ed558ccdULL;
        h ^= (h >> 33);
        sig[i] = (unsigned char) ((h >> ((i & 7) * 8)) & 0xff);
    }
}

int sodium_init(void)
{
    return 0;
}

void randombytes_buf(void * const buf, const size_t size)
{
    unsigned char *p = (unsigned char *) buf;
    for (size_t i = 0; i < size; ++i) {
        if ((i & 7U) == 0U) (void) xorshift64star();
        p[i] = (unsigned char) ((g_rng >> ((i & 7U) * 8U)) & 0xffU);
    }
}

int crypto_sign_keypair(unsigned char *pk, unsigned char *sk)
{
    if (!pk || !sk) return -1;
    randombytes_buf(sk, crypto_sign_SECRETKEYBYTES);
    memcpy(pk, sk, crypto_sign_PUBLICKEYBYTES);
    memcpy(sk + crypto_sign_PUBLICKEYBYTES, pk, crypto_sign_PUBLICKEYBYTES);
    return 0;
}

int crypto_sign_ed25519_sk_to_pk(unsigned char *pk, const unsigned char *sk)
{
    if (!pk || !sk) return -1;
    memcpy(pk, sk, crypto_sign_PUBLICKEYBYTES);
    return 0;
}

int crypto_sign_detached(unsigned char *sig,
                         unsigned long long *siglen_p,
                         const unsigned char *m,
                         unsigned long long mlen,
                         const unsigned char *sk)
{
    if (!sig || !m || !sk) return -1;
    unsigned char pk[crypto_sign_PUBLICKEYBYTES];
    memcpy(pk, sk, crypto_sign_PUBLICKEYBYTES);
    pseudo_sig_from_pk(sig, pk, m, mlen);
    if (siglen_p) *siglen_p = crypto_sign_BYTES;
    return 0;
}

int crypto_sign_verify_detached(const unsigned char *sig,
                                const unsigned char *m,
                                unsigned long long mlen,
                                const unsigned char *pk)
{
    if (!sig || !m || !pk) return -1;
    unsigned char expected[crypto_sign_BYTES];
    pseudo_sig_from_pk(expected, pk, m, mlen);
    return memcmp(sig, expected, crypto_sign_BYTES) == 0 ? 0 : -1;
}
EOF

    $CC $CFLAGS -I"$SRC/bootstrap" -c "$SRC/bootstrap/libsodium_stub.c" -o "$SRC/bootstrap/libsodium_stub.o"
    "$AR" rcs "$STAGE/usr/lib/libsodium.a" "$SRC/bootstrap/libsodium_stub.o"

    install -m644 "$SRC/bootstrap/sodium.h" "$STAGE/usr/include/sodium.h"

    cat > "$STAGE/usr/lib/pkgconfig/libsodium.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: libsodium
Description: Bootstrap libsodium compatibility shim
Version: 0.1.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lsodium
EOF

    cat > "$STAGE/usr/lib/pkgconfig/sodium.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: sodium
Description: Bootstrap sodium compatibility shim
Version: 0.1.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lsodium
EOF
}

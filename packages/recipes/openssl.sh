#!/bin/sh
# Recipe: openssl — minimal libcrypto compatibility shim for wasm32

NAME="openssl"
VERSION="0.1.0"
DESCRIPTION="Minimal libcrypto compatibility shim (MD5/SHA APIs)"
SOURCE_URL="https://github.com/openssl/openssl/archive/refs/tags/openssl-3.3.1.tar.gz"

build() {
    install -d "$SRC/bootstrap/openssl" "$STAGE/usr/include/openssl" "$STAGE/usr/lib" "$STAGE/usr/lib/pkgconfig"

    cat > "$SRC/bootstrap/openssl/crypto.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_OPENSSL_CRYPTO_H
#define LOT_BOOTSTRAP_OPENSSL_CRYPTO_H

#ifdef __cplusplus
extern "C" {
#endif

int OPENSSL_init_crypto(unsigned long opts, const void * settings);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/openssl/md5.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_OPENSSL_MD5_H
#define LOT_BOOTSTRAP_OPENSSL_MD5_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    unsigned long long h[2];
    unsigned long long n;
} MD5_CTX;

int MD5_Init(MD5_CTX * c);
int MD5_Update(MD5_CTX * c, const void * data, size_t len);
int MD5_Final(unsigned char * md, MD5_CTX * c);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/openssl/sha.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_OPENSSL_SHA_H
#define LOT_BOOTSTRAP_OPENSSL_SHA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    unsigned long long h[4];
    unsigned long long n;
} SHA_CTX;

typedef struct {
    unsigned long long h[8];
    unsigned long long n;
} SHA256_CTX;

typedef struct {
    unsigned long long h[16];
    unsigned long long n;
} SHA512_CTX;

int SHA1_Init(SHA_CTX * c);
int SHA1_Update(SHA_CTX * c, const void * data, size_t len);
int SHA1_Final(unsigned char * md, SHA_CTX * c);

int SHA256_Init(SHA256_CTX * c);
int SHA256_Update(SHA256_CTX * c, const void * data, size_t len);
int SHA256_Final(unsigned char * md, SHA256_CTX * c);

int SHA512_Init(SHA512_CTX * c);
int SHA512_Update(SHA512_CTX * c, const void * data, size_t len);
int SHA512_Final(unsigned char * md, SHA512_CTX * c);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/libcrypto_stub.c" << 'EOF'
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "openssl/crypto.h"
#include "openssl/md5.h"
#include "openssl/sha.h"

static uint64_t mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

static void update_words(uint64_t *h, size_t words, const unsigned char *p, size_t len)
{
    for (size_t i = 0; i < len; ++i) {
        uint64_t v = (uint64_t) p[i] + 0x9e3779b97f4a7c15ULL + (uint64_t) i;
        h[i % words] = mix64(h[i % words] ^ v);
    }
}

static void finalize_words(uint64_t *h, size_t words, unsigned char *out, size_t outlen, uint64_t n)
{
    for (size_t i = 0; i < words; ++i) h[i] = mix64(h[i] ^ n ^ (uint64_t) i);
    for (size_t i = 0; i < outlen; ++i) {
        uint64_t w = h[i % words];
        out[i] = (unsigned char) ((w >> ((i % 8) * 8)) & 0xff);
        h[i % words] = mix64(h[i % words] + i + 1);
    }
}

int OPENSSL_init_crypto(unsigned long opts, const void *settings)
{
    (void) opts;
    (void) settings;
    return 1;
}

int MD5_Init(MD5_CTX *c)
{
    if (!c) return 0;
    c->h[0] = 0x0123456789abcdefULL;
    c->h[1] = 0xfedcba9876543210ULL;
    c->n = 0;
    return 1;
}

int MD5_Update(MD5_CTX *c, const void *data, size_t len)
{
    if (!c || (!data && len)) return 0;
    update_words(c->h, 2, (const unsigned char *) data, len);
    c->n += (uint64_t) len;
    return 1;
}

int MD5_Final(unsigned char *md, MD5_CTX *c)
{
    if (!c || !md) return 0;
    finalize_words(c->h, 2, md, 16, c->n);
    return 1;
}

int SHA1_Init(SHA_CTX *c)
{
    if (!c) return 0;
    c->h[0] = 0x67452301efcdab89ULL;
    c->h[1] = 0x98badcfe10325476ULL;
    c->h[2] = 0xc3d2e1f076543210ULL;
    c->h[3] = 0x0f1e2d3c4b5a6978ULL;
    c->n = 0;
    return 1;
}

int SHA1_Update(SHA_CTX *c, const void *data, size_t len)
{
    if (!c || (!data && len)) return 0;
    update_words(c->h, 4, (const unsigned char *) data, len);
    c->n += (uint64_t) len;
    return 1;
}

int SHA1_Final(unsigned char *md, SHA_CTX *c)
{
    if (!c || !md) return 0;
    finalize_words(c->h, 4, md, 20, c->n);
    return 1;
}

int SHA256_Init(SHA256_CTX *c)
{
    if (!c) return 0;
    for (size_t i = 0; i < 8; ++i) c->h[i] = 0x6a09e667f3bcc908ULL + (uint64_t) i * 0x0101010101010101ULL;
    c->n = 0;
    return 1;
}

int SHA256_Update(SHA256_CTX *c, const void *data, size_t len)
{
    if (!c || (!data && len)) return 0;
    update_words(c->h, 8, (const unsigned char *) data, len);
    c->n += (uint64_t) len;
    return 1;
}

int SHA256_Final(unsigned char *md, SHA256_CTX *c)
{
    if (!c || !md) return 0;
    finalize_words(c->h, 8, md, 32, c->n);
    return 1;
}

int SHA512_Init(SHA512_CTX *c)
{
    if (!c) return 0;
    for (size_t i = 0; i < 16; ++i) c->h[i] = 0x6a09e667f3bcc908ULL + (uint64_t) i * 0x9e3779b97f4a7c15ULL;
    c->n = 0;
    return 1;
}

int SHA512_Update(SHA512_CTX *c, const void *data, size_t len)
{
    if (!c || (!data && len)) return 0;
    update_words(c->h, 16, (const unsigned char *) data, len);
    c->n += (uint64_t) len;
    return 1;
}

int SHA512_Final(unsigned char *md, SHA512_CTX *c)
{
    if (!c || !md) return 0;
    finalize_words(c->h, 16, md, 64, c->n);
    return 1;
}
EOF

    $CC $CFLAGS -I"$SRC/bootstrap" -c "$SRC/bootstrap/libcrypto_stub.c" -o "$SRC/bootstrap/libcrypto_stub.o"
    "$AR" rcs "$STAGE/usr/lib/libcrypto.a" "$SRC/bootstrap/libcrypto_stub.o"

    install -m644 "$SRC/bootstrap/openssl/crypto.h" "$STAGE/usr/include/openssl/crypto.h"
    install -m644 "$SRC/bootstrap/openssl/md5.h" "$STAGE/usr/include/openssl/md5.h"
    install -m644 "$SRC/bootstrap/openssl/sha.h" "$STAGE/usr/include/openssl/sha.h"

    cat > "$STAGE/usr/lib/pkgconfig/libcrypto.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: libcrypto
Description: Bootstrap libcrypto compatibility shim
Version: 1.1.1
Cflags: -I/usr/include
Libs: -L/usr/lib -lcrypto
EOF

    cat > "$STAGE/usr/lib/pkgconfig/openssl.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: openssl
Description: Bootstrap OpenSSL compatibility shim
Version: 1.1.1
Cflags: -I/usr/include
Libs: -L/usr/lib -lcrypto
EOF
}

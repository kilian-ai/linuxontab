#!/bin/sh
# Recipe: brotli — minimal encoder/decoder API shim for wasm32

NAME="brotli"
VERSION="0.1.0"
DESCRIPTION="Minimal brotli compatibility shim"
SOURCE_URL="https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz"

build() {
    install -d "$SRC/bootstrap/brotli" "$STAGE/usr/include/brotli" "$STAGE/usr/lib" "$STAGE/usr/lib/pkgconfig"

    cat > "$SRC/bootstrap/brotli/decode.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_BROTLI_DECODE_H
#define LOT_BOOTSTRAP_BROTLI_DECODE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BrotliDecoderStateStruct BrotliDecoderState;
typedef int BROTLI_BOOL;

BrotliDecoderState * BrotliDecoderCreateInstance(void *alloc_func, void *free_func, void *opaque);
void BrotliDecoderDestroyInstance(BrotliDecoderState *state);
BROTLI_BOOL BrotliDecoderDecompressStream(BrotliDecoderState *state,
                                          size_t *available_in,
                                          const uint8_t **next_in,
                                          size_t *available_out,
                                          uint8_t **next_out,
                                          size_t *total_out);
BROTLI_BOOL BrotliDecoderIsFinished(const BrotliDecoderState *state);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/brotli/encode.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_BROTLI_ENCODE_H
#define LOT_BOOTSTRAP_BROTLI_ENCODE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BrotliEncoderStateStruct BrotliEncoderState;
typedef int BROTLI_BOOL;

typedef enum {
  BROTLI_OPERATION_PROCESS = 0,
  BROTLI_OPERATION_FLUSH = 1,
  BROTLI_OPERATION_FINISH = 2,
  BROTLI_OPERATION_EMIT_METADATA = 3
} BrotliEncoderOperation;

BrotliEncoderState * BrotliEncoderCreateInstance(void *alloc_func, void *free_func, void *opaque);
void BrotliEncoderDestroyInstance(BrotliEncoderState *state);
BROTLI_BOOL BrotliEncoderCompressStream(BrotliEncoderState *state,
                                        BrotliEncoderOperation op,
                                        size_t *available_in,
                                        const uint8_t **next_in,
                                        size_t *available_out,
                                        uint8_t **next_out,
                                        size_t *total_out);
BROTLI_BOOL BrotliEncoderIsFinished(const BrotliEncoderState *state);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/brotli_stub.c" << 'EOF'
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "brotli/decode.h"
#include "brotli/encode.h"

struct BrotliDecoderStateStruct { int finished; };
struct BrotliEncoderStateStruct { int finished; };

static size_t copy_stream(size_t *available_in, const uint8_t **next_in, size_t *available_out, uint8_t **next_out)
{
    if (!available_in || !next_in || !available_out || !next_out || !*next_in || !*next_out)
        return 0;
    size_t n = *available_in < *available_out ? *available_in : *available_out;
    for (size_t i = 0; i < n; ++i) (*next_out)[i] = (*next_in)[i];
    *next_in += n;
    *next_out += n;
    *available_in -= n;
    *available_out -= n;
    return n;
}

BrotliDecoderState * BrotliDecoderCreateInstance(void *alloc_func, void *free_func, void *opaque)
{
    (void) alloc_func;
    (void) free_func;
    (void) opaque;
    BrotliDecoderState *s = (BrotliDecoderState *) malloc(sizeof(BrotliDecoderState));
    if (s) s->finished = 0;
    return s;
}

void BrotliDecoderDestroyInstance(BrotliDecoderState *state)
{
    free(state);
}

BROTLI_BOOL BrotliDecoderDecompressStream(BrotliDecoderState *state,
                                          size_t *available_in,
                                          const uint8_t **next_in,
                                          size_t *available_out,
                                          uint8_t **next_out,
                                          size_t *total_out)
{
    size_t n = copy_stream(available_in, next_in, available_out, next_out);
    if (total_out) *total_out += n;
    if (state && available_in && *available_in == 0) state->finished = 1;
    return 1;
}

BROTLI_BOOL BrotliDecoderIsFinished(const BrotliDecoderState *state)
{
    return state ? state->finished : 1;
}

BrotliEncoderState * BrotliEncoderCreateInstance(void *alloc_func, void *free_func, void *opaque)
{
    (void) alloc_func;
    (void) free_func;
    (void) opaque;
    BrotliEncoderState *s = (BrotliEncoderState *) malloc(sizeof(BrotliEncoderState));
    if (s) s->finished = 0;
    return s;
}

void BrotliEncoderDestroyInstance(BrotliEncoderState *state)
{
    free(state);
}

BROTLI_BOOL BrotliEncoderCompressStream(BrotliEncoderState *state,
                                        BrotliEncoderOperation op,
                                        size_t *available_in,
                                        const uint8_t **next_in,
                                        size_t *available_out,
                                        uint8_t **next_out,
                                        size_t *total_out)
{
    size_t n = copy_stream(available_in, next_in, available_out, next_out);
    if (total_out) *total_out += n;
    if (state && op == BROTLI_OPERATION_FINISH && (!available_in || *available_in == 0)) state->finished = 1;
    return 1;
}

BROTLI_BOOL BrotliEncoderIsFinished(const BrotliEncoderState *state)
{
    return state ? state->finished : 1;
}
EOF

    $CC $CFLAGS -I"$SRC/bootstrap" -c "$SRC/bootstrap/brotli_stub.c" -o "$SRC/bootstrap/brotli_stub.o"
    "$AR" rcs "$STAGE/usr/lib/libbrotlicommon.a" "$SRC/bootstrap/brotli_stub.o"
    "$AR" rcs "$STAGE/usr/lib/libbrotlidec.a" "$SRC/bootstrap/brotli_stub.o"
    "$AR" rcs "$STAGE/usr/lib/libbrotlienc.a" "$SRC/bootstrap/brotli_stub.o"

    install -m644 "$SRC/bootstrap/brotli/decode.h" "$STAGE/usr/include/brotli/decode.h"
    install -m644 "$SRC/bootstrap/brotli/encode.h" "$STAGE/usr/include/brotli/encode.h"

    cat > "$STAGE/usr/lib/pkgconfig/libbrotlicommon.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: libbrotlicommon
Description: Bootstrap brotli common shim
Version: 0.1.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lbrotlicommon
EOF

    cat > "$STAGE/usr/lib/pkgconfig/libbrotlidec.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: libbrotlidec
Description: Bootstrap brotli decoder shim
Version: 0.1.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lbrotlidec
EOF

    cat > "$STAGE/usr/lib/pkgconfig/libbrotlienc.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: libbrotlienc
Description: Bootstrap brotli encoder shim
Version: 0.1.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lbrotlienc
EOF
}

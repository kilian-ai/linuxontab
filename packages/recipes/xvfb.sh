#!/bin/sh
# Recipe: xvfb - headless X server from xorg-server

NAME="xvfb"
VERSION="21.1.13"
DESCRIPTION="Virtual framebuffer X server"
SOURCE_URL="https://www.x.org/archive/individual/xserver/xorg-server-${VERSION}.tar.xz"
SOURCE_SHA256=""

XORGPROTO_VER="2024.1"
XORGPROTO_URL="https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/archive/xorgproto-${XORGPROTO_VER}/xorgproto-xorgproto-${XORGPROTO_VER}.tar.gz"

build() {
    cd "$SRC"

    XPROTO_ARCHIVE="/tmp/lot-src-xorgproto-${XORGPROTO_VER}.tar.gz"
    XPROTO_SRC="/tmp/lot-build/xvfb-xorgproto"
    if [ ! -f "$XPROTO_ARCHIVE" ]; then
        echo "==> Downloading xorgproto $XORGPROTO_VER"
        curl -L --fail -o "$XPROTO_ARCHIVE" "$XORGPROTO_URL"
    fi
    rm -rf "$XPROTO_SRC"
    mkdir -p "$XPROTO_SRC"
    tar xzf "$XPROTO_ARCHIVE" -C "$XPROTO_SRC" --strip-components=1

    [ -f "/tmp/lot-build/pixman/stage/usr/lib/libpixman-1.a" ] || {
        echo "Missing /tmp/lot-build/pixman staged library. Run ./packages/build-package.sh pixman first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/xkbfile/stage/usr/lib/libxkbfile.a" ] || {
        echo "Missing /tmp/lot-build/xkbfile staged library. Run ./packages/build-package.sh xkbfile first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXfont2/stage/usr/lib/libXfont2.a" ] || {
        echo "Missing /tmp/lot-build/libXfont2 staged library. Run ./packages/build-package.sh libXfont2 first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/fontenc/stage/usr/lib/libfontenc.a" ] || {
        echo "Missing /tmp/lot-build/fontenc staged library. Run ./packages/build-package.sh fontenc first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/freetype/stage/usr/lib/libfreetype.a" ] || {
        echo "Missing /tmp/lot-build/freetype staged library. Run ./packages/build-package.sh freetype first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/zlib/stage/usr/lib/libz.a" ] || {
        echo "Missing /tmp/lot-build/zlib staged library. Run ./packages/build-package.sh zlib first." >&2
        exit 1
    }
    [ -f "/tmp/lot-build/libXau/stage/usr/lib/libXau.a" ] || {
        echo "Missing /tmp/lot-build/libXau staged library. Run ./packages/build-package.sh libXau first." >&2
        exit 1
    }

    DEPS_PREFIX="/tmp/lot-build/xvfb-deps-prefix"
    rm -rf "$DEPS_PREFIX"
    mkdir -p "$DEPS_PREFIX/include" "$DEPS_PREFIX/lib" "$DEPS_PREFIX/include/libsha1"
    cp -R /tmp/lot-build/pixman/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/xtrans/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/xkbfile/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXfont2/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/fontenc/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/freetype/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -R /tmp/lot-build/libXau/stage/usr/include/* "$DEPS_PREFIX/include/"
    cp -f /tmp/lot-build/zlib/stage/usr/include/zlib.h /tmp/lot-build/zlib/stage/usr/include/zconf.h "$DEPS_PREFIX/include/"
    cp -f /tmp/lot-build/pixman/stage/usr/lib/libpixman-1.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/xkbfile/stage/usr/lib/libxkbfile.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXfont2/stage/usr/lib/libXfont2.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/fontenc/stage/usr/lib/libfontenc.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/freetype/stage/usr/lib/libfreetype.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/zlib/stage/usr/lib/libz.a "$DEPS_PREFIX/lib/"
    cp -f /tmp/lot-build/libXau/stage/usr/lib/libXau.a "$DEPS_PREFIX/lib/"
    mkdir -p "$DEPS_PREFIX/include/X11/Xtrans"
    cp -f /tmp/lot-build/xtrans/src/Xtransint.h "$DEPS_PREFIX/include/X11/Xtrans/"
    cp -f /tmp/lot-build/xtrans/src/transport.c "$DEPS_PREFIX/include/X11/Xtrans/"
    cp -f /tmp/lot-build/xtrans/src/Xtrans*.c "$DEPS_PREFIX/include/X11/Xtrans/"

    cat > "$DEPS_PREFIX/include/libsha1.h" << 'EOF'
#ifndef LOT_LIBSHA1_H
#define LOT_LIBSHA1_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t state[5];
    uint64_t bit_count;
    uint8_t buffer[64];
    size_t buffer_len;
} sha1_ctx;

void sha1_begin(sha1_ctx *ctx);
void sha1_hash(const void *data, size_t len, sha1_ctx *ctx);
void sha1_end(unsigned char digest[20], sha1_ctx *ctx);

#endif
EOF

    cat > "$DEPS_PREFIX/lib/sha1.c" << 'EOF'
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "libsha1.h"

static uint32_t rol32(uint32_t value, unsigned int bits) {
    return (value << bits) | (value >> (32U - bits));
}

static void sha1_transform(sha1_ctx *ctx, const uint8_t block[64]) {
    uint32_t words[80];
    uint32_t a, b, c, d, e;
    unsigned int index;

    for (index = 0; index < 16; index++) {
        words[index] = ((uint32_t) block[index * 4] << 24) |
                       ((uint32_t) block[index * 4 + 1] << 16) |
                       ((uint32_t) block[index * 4 + 2] << 8) |
                       (uint32_t) block[index * 4 + 3];
    }
    for (index = 16; index < 80; index++) {
        words[index] = rol32(words[index - 3] ^ words[index - 8] ^
                             words[index - 14] ^ words[index - 16], 1);
    }

    a = ctx->state[0];
    b = ctx->state[1];
    c = ctx->state[2];
    d = ctx->state[3];
    e = ctx->state[4];

    for (index = 0; index < 80; index++) {
        uint32_t f;
        uint32_t k;
        uint32_t temp;

        if (index < 20) {
            f = (b & c) | ((~b) & d);
            k = 0x5A827999U;
        } else if (index < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1U;
        } else if (index < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDCU;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6U;
        }

        temp = rol32(a, 5) + f + e + k + words[index];
        e = d;
        d = c;
        c = rol32(b, 30);
        b = a;
        a = temp;
    }

    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
}

void sha1_begin(sha1_ctx *ctx) {
    ctx->state[0] = 0x67452301U;
    ctx->state[1] = 0xEFCDAB89U;
    ctx->state[2] = 0x98BADCFEU;
    ctx->state[3] = 0x10325476U;
    ctx->state[4] = 0xC3D2E1F0U;
    ctx->bit_count = 0;
    ctx->buffer_len = 0;
}

void sha1_hash(const void *data, size_t len, sha1_ctx *ctx) {
    const uint8_t *bytes = (const uint8_t *) data;

    ctx->bit_count += (uint64_t) len * 8U;
    while (len > 0) {
        size_t copy_len = 64U - ctx->buffer_len;
        if (copy_len > len) {
            copy_len = len;
        }
        memcpy(ctx->buffer + ctx->buffer_len, bytes, copy_len);
        ctx->buffer_len += copy_len;
        bytes += copy_len;
        len -= copy_len;

        if (ctx->buffer_len == 64U) {
            sha1_transform(ctx, ctx->buffer);
            ctx->buffer_len = 0;
        }
    }
}

void sha1_end(unsigned char digest[20], sha1_ctx *ctx) {
    size_t index;
    uint64_t bit_count = ctx->bit_count;

    ctx->buffer[ctx->buffer_len++] = 0x80U;
    if (ctx->buffer_len > 56U) {
        while (ctx->buffer_len < 64U) {
            ctx->buffer[ctx->buffer_len++] = 0;
        }
        sha1_transform(ctx, ctx->buffer);
        ctx->buffer_len = 0;
    }
    while (ctx->buffer_len < 56U) {
        ctx->buffer[ctx->buffer_len++] = 0;
    }
    for (index = 0; index < 8; index++) {
        ctx->buffer[56U + index] = (uint8_t) (bit_count >> (56U - 8U * index));
    }
    sha1_transform(ctx, ctx->buffer);

    for (index = 0; index < 5; index++) {
        digest[index * 4] = (unsigned char) (ctx->state[index] >> 24);
        digest[index * 4 + 1] = (unsigned char) (ctx->state[index] >> 16);
        digest[index * 4 + 2] = (unsigned char) (ctx->state[index] >> 8);
        digest[index * 4 + 3] = (unsigned char) ctx->state[index];
    }
}
EOF

    $CC $CFLAGS -I"$DEPS_PREFIX/include" -c "$DEPS_PREFIX/lib/sha1.c" -o "$DEPS_PREFIX/lib/sha1.o"
    $AR rcs "$DEPS_PREFIX/lib/libsha1.a" "$DEPS_PREFIX/lib/sha1.o"
    $RANLIB "$DEPS_PREFIX/lib/libsha1.a"
    rm -f "$DEPS_PREFIX/lib/sha1.c" "$DEPS_PREFIX/lib/sha1.o"

        cat > "$SRC/pkg-config" << EOF
#!/bin/sh
mod=''
last=''
have_mod=0
for arg in "\$@"; do
  case "\$arg" in
    --modversion|--cflags|--libs|--exists|--print-errors) last="\$arg" ;;
    --variable=*) last="\$arg" ;;
        '>'|'<'|'>='|'<='|'='|'!=') ;;
    -*) ;;
        *)
            if [ "\$have_mod" -eq 0 ]; then
                mod="\$arg"
                have_mod=1
            fi ;;
  esac
done
case "\$last" in
  --version) echo "1.0"; exit 0 ;;
  --exists|--print-errors)
        mod=\${mod%%[[:space:]]*}
    case "\$mod" in
    xproto|randrproto|renderproto|xextproto|inputproto|kbproto|fontsproto|fixesproto|damageproto|xcmiscproto|bigreqsproto|videoproto|compositeproto|recordproto|scrnsaverproto|resourceproto|xineramaproto|xf86vidmodeproto|xtrans|pixman-1|xkbfile|xfont2|xau|libsha1) exit 0 ;;
      *) exit 1 ;;
    esac ;;
  --modversion)
        mod=\${mod%%[[:space:]]*}
    case "\$mod" in
      xproto) echo "7.0.31" ;;
      randrproto) echo "1.6.0" ;;
      renderproto) echo "0.11.1" ;;
      xextproto) echo "7.3.0" ;;
      inputproto) echo "2.3.2" ;;
      kbproto) echo "1.0.7" ;;
      fontsproto) echo "2.1.3" ;;
      fixesproto) echo "6.0" ;;
      damageproto) echo "1.2.1" ;;
      xcmiscproto) echo "1.2.2" ;;
      bigreqsproto) echo "1.1.2" ;;
      videoproto) echo "2.3.3" ;;
      compositeproto) echo "0.4.2" ;;
      recordproto) echo "1.14.2" ;;
      scrnsaverproto) echo "1.2.3" ;;
      resourceproto) echo "1.2.0" ;;
      xineramaproto) echo "1.2.1" ;;
      xf86vidmodeproto) echo "2.3.1" ;;
      xtrans) echo "1.6.0" ;;
      pixman-1) echo "0.42.2" ;;
      xkbfile) echo "1.1.3" ;;
      xfont2) echo "2.0.7" ;;
    xau) echo "1.0.12" ;;
      libsha1) echo "1.0" ;;
      *) echo "1.0" ;;
    esac
    exit 0 ;;
  --cflags)
    case "\$mod" in
      xproto|randrproto|renderproto|xextproto|inputproto|kbproto|fontsproto|fixesproto|damageproto|xcmiscproto|bigreqsproto|videoproto|compositeproto|recordproto|scrnsaverproto|resourceproto|xineramaproto|xf86vidmodeproto) echo "-I$XPROTO_SRC/include" ;;
      xtrans) echo "-I$XPROTO_SRC/include -I$DEPS_PREFIX/include" ;;
      pixman-1) echo "-I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/pixman-1" ;;
      xkbfile) echo "-I$DEPS_PREFIX/include" ;;
      xfont2) echo "-I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/freetype2" ;;
    xau) echo "-I$DEPS_PREFIX/include" ;;
      libsha1) echo "-I$DEPS_PREFIX/include" ;;
      *) echo "" ;;
    esac
    exit 0 ;;
  --libs)
    case "\$mod" in
      pixman-1) echo "-L$DEPS_PREFIX/lib -lpixman-1" ;;
      xkbfile) echo "-L$DEPS_PREFIX/lib -lxkbfile" ;;
      xfont2) echo "-L$DEPS_PREFIX/lib -lXfont2 -lfontenc -lfreetype -lz" ;;
    xau) echo "-L$DEPS_PREFIX/lib -lXau" ;;
      libsha1) echo "-L$DEPS_PREFIX/lib -lsha1" ;;
      *) echo "" ;;
    esac
    exit 0 ;;
  --variable=*)
    case "\$last" in
      --variable=xkbconfigdir) echo "/usr/share/X11/xkb" ;;
      --variable=bindir) echo "/usr/bin" ;;
      *) echo "" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
    chmod +x "$SRC/pkg-config"

    export PKG_CONFIG="$SRC/pkg-config"

    cat > "$SRC/os/present.h" << 'EOF'
#ifndef LOT_PRESENT_H
#define LOT_PRESENT_H

#endif
EOF

    # In this reduced build, utils.c references FakeScreenFps without a definition.
    if ! rg -q '^[[:space:]]*uint32_t[[:space:]]+FakeScreenFps[[:space:]]*=' "$SRC/os/utils.c"; then
        perl -0pi -e 's/#include "present.h"/#include "present.h"\n#include <stdint.h>\nuint32_t FakeScreenFps = 60;\n/' "$SRC/os/utils.c"
    fi
    if ! rg -q '^[[:space:]]*int[[:space:]]+fork\(void\);' "$SRC/os/utils.c"; then
        perl -0pi -e 's/#include "extension.h"\n#include <signal.h>/#include "extension.h"\n#include <signal.h>\nint fork\(void\);/' "$SRC/os/utils.c"
    fi

    # ── Native wasm-EH setjmp/longjmp + REAL fork ──────────────────────────
    # The X server longjmps for dispatch recovery; the old build had no working
    # setjmp/longjmp, so the first longjmp trapped (RuntimeError: unreachable ->
    # SIGSEGV at startup). Compile the whole server with the native wasm-EH sjlj
    # lowering (same fix as ash/zsh) and link sysroot/sjlj_rt_wasmeh.c. And drop
    # the old `fork()=-1` stub — fork works now (dynamic thunk), which the X
    # server needs to spawn xkbcomp. Runtime objects must be built BEFORE
    # ./configure so its setjmp/fork link probes resolve.
    CC="$CC -mexception-handling -mllvm -wasm-enable-sjlj"; export CC
    "$CLANG" -target wasm32 --sysroot="$SYSROOT" -O2 -matomics -mbulk-memory \
        -mexception-handling -mllvm -wasm-enable-sjlj \
        -c "$REPO_ROOT/sysroot/sjlj_rt_wasmeh.c" -o "$DEPS_PREFIX/lib/lot_sjlj_rt.o"
    "$CLANG" -target wasm32 --sysroot="$SYSROOT" -O2 -matomics -mbulk-memory \
        -c "$REPO_ROOT/sysroot/wasm_fork.c" -o "$DEPS_PREFIX/lib/lot_wasm_fork.o"

    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --disable-docs \
        --disable-devel-docs \
        --disable-composite \
        --disable-mitshm \
        --disable-xres \
        --disable-record \
        --disable-xv \
        --disable-xvmc \
        --disable-dga \
        --disable-screensaver \
        --disable-present \
        --disable-xinerama \
        --disable-xace \
        --disable-dpms \
        --disable-config-hal \
        --disable-config-udev \
        --disable-config-udev-kms \
        --disable-linux-acpi \
        --disable-linux-apm \
        --disable-glx \
        --disable-xdmcp \
        --disable-xorg \
        --enable-xvfb \
        --disable-xnest \
        --disable-kdrive \
        --disable-xephyr \
        --disable-libunwind \
        --disable-input-thread \
        --disable-dri \
        --disable-dri2 \
        --disable-dri3 \
        --with-default-font-path=/usr/share/fonts \
        --with-xkb-path=/usr/share/X11/xkb \
        --with-xkb-output=/tmp \
        --with-xkb-bin-directory=/usr/bin \
        --with-sha1=libsha1 \
        CC="$CC" \
        XSERVERLIBS_CFLAGS="-I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/pixman-1 -I$DEPS_PREFIX/include/freetype2" \
        XSERVERLIBS_LIBS="-L$DEPS_PREFIX/lib -lpixman-1 -lXfont2 -lfontenc -lfreetype -lz -lXau" \
        CPPFLAGS="-I$XPROTO_SRC/include -I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/pixman-1 -I$DEPS_PREFIX/include/freetype2" \
        CFLAGS="$CFLAGS -include unistd.h -DSelect=select -I$XPROTO_SRC/include -I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/pixman-1 -I$DEPS_PREFIX/include/freetype2" \
        LDFLAGS="$LDFLAGS -L$DEPS_PREFIX/lib" \
        LIBS="$CRT1 -lsha1 -lXfont2 -lxkbfile -lpixman-1 -lfontenc -lfreetype -lz -lc -lm"

    # busfault.c relies on mmap constants not available in this reduced target.
    # Remove busfault.lo from os/Makefile but provide stub symbols so callers link.
    sed -i.bak 's/[[:space:]]busfault\.lo//g' os/Makefile || true
    cat > os/lot_busfault_stubs.c << 'EOFSTUB'
/* Stubs for busfault_init / busfault_check — no mmap-based bus fault handling in WASM. */
void busfault_init(void) {}
void busfault_check(void) {}
EOFSTUB
    $CC $CPPFLAGS $CFLAGS -c os/lot_busfault_stubs.c -o os/lot_busfault_stubs.o
    # (fork stub removed — real fork()/vfork() come from lot_wasm_fork.o, built
    # above from sysroot/wasm_fork.c so the X server can spawn xkbcomp etc.)

    # Keep crt1 for configure probes, but remove it from recursive make link lines
    # to avoid duplicate _start during final Xvfb link.
    find . -name Makefile -type f -exec sed -i.bak "s|$CRT1||g" {} +
    # Don't build the test/ subtree — it needs X11/Xlib.h and other things not available here.
    printf 'all:\ncheck:\ninstall:\n' > test/Makefile
    # Provide a default-visible main() for Xvfb that forwards to dix_main().
    cat > dix/lot_stubmain.c << 'EOF'
#include <stddef.h>

int dix_main(int argc, char *argv[], char *envp[]);

__attribute__((visibility("default")))
int main(int argc, char *argv[])
{
    return dix_main(argc, argv, NULL);
}
EOF
    $CC $CPPFLAGS $CFLAGS -c dix/lot_stubmain.c -o dix/lot_stubmain.o
    # Re-add startup and compiler-rt only for the final Xvfb executable link.
    sed -i.bak "s|^Xvfb_LDADD = \(.*\)$|Xvfb_LDADD = $CRT1 ../../dix/lot_stubmain.o ../../os/lot_busfault_stubs.o $DEPS_PREFIX/lib/lot_wasm_fork.o $DEPS_PREFIX/lib/lot_sjlj_rt.o \1 $BUILTINS|" hw/vfb/Makefile

    make -j4

    mkdir -p "$STAGE/bin"
    cp -f hw/vfb/Xvfb "$STAGE/bin/Xvfb"
}
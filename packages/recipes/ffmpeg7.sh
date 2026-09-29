#!/bin/sh
# Recipe: ffmpeg7 — ffmpeg 7.0.2 + ffprobe with pthreads, opt-in (ffmpeg7/ffprobe7).
#
#   ffprobe movie.mkv
#   ffmpeg -i movie.mkv -c copy -movflags frag_keyframe+empty_moov out.mp4   (remux)
#   ffmpeg -i in.m2v -f rawvideo -pix_fmt yuv420p -                          (decode → page)
#
# Opt-in build of ffmpeg 7.0.2 with pthreads, installed as ffmpeg7/ffprobe7
# next to the single-threaded 5.1 default. Its always-threaded CLI (demux/
# decode/filter/encode/mux threads since 7.0) used to deadlock when another
# threaded process ran alongside (2026-09-02: h264.mkv run 2 hung with python
# starting; hung runs could not be ^C'd). Cause: the no-MMU kernel keyed
# futexes by address alone, and wasm processes share address layouts, so one
# process's FUTEX_WAKE woke a waiter in another — fixed in the 7.1 kernel
# (3c3768d). r2 added the locked allocator and per-thread TLS. Verified on the
# fixed kernel: two concurrent threaded 720p encode/probe/decode loops 8/8
# each, and 20/20 alone next to busy loops.
#
# Cross notes: ffmpeg's configure supports cross builds natively and skips
# every exec test under --enable-cross-compile, so it needs no answer table —
# just the lot-cc.sh wrapper (link line + shim objects on every link) and a
# GNU-format ar. The mmap shim is deliberately NOT linked: with no mmap symbol
# configure sets HAVE_MMAP=0 and libavutil's av_file_map falls back to read().
# The ld128 shim IS linked: musl's printf formats doubles through long double,
# and the sysroot's ld80/binary128 mismatch turns every %f into a stack
# overflow (the htop "segfault").

NAME="ffmpeg7"
FFMPEG_UPSTREAM="7.0.2"
VERSION="${FFMPEG_UPSTREAM}-r3"   # r1: fixed-sysroot brk, heap no longer capped at ~60 MB
                                  # r2: locked dlmalloc (wasm_dlmalloc_mt), per-thread TLS
                                  # r3: same code, EXPERIMENTAL dropped (kernel futex fix)
DESCRIPTION="ffmpeg 7.0 + ffprobe 7.0 with pthreads — installs as ffmpeg7 / ffprobe7"
SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_UPSTREAM}.tar.gz"
SOURCE_SHA256=""

build() {
    . "$RECIPES_DIR/_webdeps.sh"
    webdeps_env
    # Allocator: sbrk-only dlmalloc instead of musl's mallocng. mallocng backs
    # every allocation above ~128 KB with mmap/munmap/mremap, which this
    # platform does not have; large free()/realloc() then trap in its
    # consistency checks (av_buffer_pool_uninit → free, av_new_packet →
    # realloc: "unreachable", shown as Segmentation fault). Every >=720p frame
    # buffer is that big. See sysroot/wasm_dlmalloc.c. No mmap shim, no fork.
    # The _mt variant: every ffmpeg 7 CLI stage runs on its own thread and
    # they all allocate — the unlocked allocator (r1 and earlier) raced.
    # wasm_clone.c gives each thread its own stack and _Thread_local block.
    $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/wasm_dlmalloc_mt.c" -o "$WEBDEPS_OBJS/wasm_dlmalloc_mt.o"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_clone.c" -o "$WEBDEPS_OBJS/wasm_clone.o"
    export LOT_LINK_OBJS="$WEBDEPS_OBJS/wasm_dlmalloc_mt.o $WEBDEPS_OBJS/wasm_ld128.o $WEBDEPS_OBJS/wasm_clone.o"

    NM=$(find /nix/store -maxdepth 3 -name "llvm-nm" -path "*llvm-19*" 2>/dev/null | sort | head -1)
    [ -x "$NM" ] || NM=nm

    cd "$SRC"
    ./configure \
        --prefix=/usr/local \
        --enable-cross-compile --target-os=linux --arch=generic \
        --cc="$LOTCC" --host-cc=cc --ar="$WEBDEPS_AR" --ranlib="$RANLIB" --nm="$NM" --strip=true \
        --pkg-config=false \
        --extra-cflags="$CFLAGS -D_GNU_SOURCE" \
        --disable-asm --disable-x86asm \
        --enable-pthreads --disable-w32threads --disable-os2threads \
        --disable-autodetect --disable-doc --disable-debug \
        --disable-shared --enable-static \
        --disable-ffplay \
        --disable-indevs --disable-outdevs --enable-indev=lavfi \
        --disable-vulkan --disable-cuda-llvm \
        || { echo "==> configure failed; ffbuild/config.log tail:"; tail -40 ffbuild/config.log; exit 1; }

    grep -n "^HAVE_MMAP\|^HAVE_PTHREADS\|^CONFIG_NETWORK\|^ARCH_" ffbuild/config.mak | head -8

    # The *_g targets are the real link outputs; the unsuffixed ones are made
    # by $(STRIP), which is `true` here (no wasm strip — asyncify rewrites the
    # module anyway), so install the _g binaries directly.
    make -j8 ffmpeg_g ffprobe_g

    webdeps_install 755 ffmpeg_g  "$STAGE/usr/local/bin/ffmpeg7"
    webdeps_install 755 ffprobe_g "$STAGE/usr/local/bin/ffprobe7"
    rmdir "$STAGE/bin" 2>/dev/null || true
}

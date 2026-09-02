#!/bin/sh
# Recipe: ffmpeg — ffmpeg + ffprobe, compiled to wasm32 for the guest.
#
#   ffprobe movie.mkv
#   ffmpeg -i movie.mkv -c copy -movflags frag_keyframe+empty_moov out.mp4   (remux)
#   ffmpeg -i in.m2v -f rawvideo -pix_fmt yuv420p -                          (decode → page)
#
# Scope of this first build: every built-in demuxer/decoder/encoder/filter,
# no external libraries (no x264/dav1d/TLS), no asm, NO THREADS. Why 5.1 (LTS)
# and not 6.x/7.x: from 6.0 on the ffmpeg CLI hard-requires pthreads (configure:
# ffmpeg_deps="... threads" — demux/mux, later decode/filter/encode, run as
# separate threads) and on this kernel a 7.0.2 build ran `-version` fine but
# hung, uninterruptibly and before its first syscall, on any real job: a
# mutex+condvar handoff between two threads loses its wakeup (repro:
# pthread_pingpong, see memory). 5.1 is the last CLI that runs fully
# single-threaded, which is also the honest baseline for measuring decode
# speed here. SIMD and (once futex is fixed) threads + 7.x are follow-ups.
#
# Cross notes: ffmpeg's configure supports cross builds natively and skips
# every exec test under --enable-cross-compile, so it needs no answer table —
# just the lot-cc.sh wrapper (link line + shim objects on every link) and a
# GNU-format ar. The mmap shim is deliberately NOT linked: with no mmap symbol
# configure sets HAVE_MMAP=0 and libavutil's av_file_map falls back to read().
# The ld128 shim IS linked: musl's printf formats doubles through long double,
# and the sysroot's ld80/binary128 mismatch turns every %f into a stack
# overflow (the htop "segfault").

NAME="ffmpeg"
VERSION="5.1.6"
DESCRIPTION="ffmpeg + ffprobe — demux/remux/decode any format (no asm, single-threaded)"
SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.gz"
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
    $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/wasm_dlmalloc.c" -o "$WEBDEPS_OBJS/wasm_dlmalloc.o"
    export LOT_LINK_OBJS="$WEBDEPS_OBJS/wasm_dlmalloc.o $WEBDEPS_OBJS/wasm_ld128.o"

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
        --disable-pthreads --disable-w32threads --disable-os2threads \
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

    webdeps_install 755 ffmpeg_g  "$STAGE/usr/local/bin/ffmpeg"
    webdeps_install 755 ffprobe_g "$STAGE/usr/local/bin/ffprobe"
    rmdir "$STAGE/bin" 2>/dev/null || true
}

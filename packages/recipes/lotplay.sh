#!/bin/sh
# Recipe: lotplay — a small video player for the X desktop (lotplay.c on
# ffmpeg's libraries + Xlib). Apps menu → Videos, or:
#
#   lotplay movie.mp4      # Space pause, ←/→ seek, Q quit
#   lotplay                # the bundled sample, looped
#
# ffmpeg is built here as static libraries with a player-sized component
# set (common video + audio decoders, demuxers and parsers, swresample; no
# encoders, filters, devices or network) — same cross setup as recipes/ffmpeg.sh: no asm, no threads,
# sbrk-only dlmalloc (frame buffers pass 128 KB, where musl mallocng needs
# mmap and traps), and the binary128 long-double shim for printf.
# Sample clip (packages/media/lotplay-sample.mp4) is generated — no
# third-party footage. Title PNG rendered with Pillow in Inter SemiBold/Medium
# (OFL): "LinuxOnTab" 42 px at y=52 and "ffmpeg decoding inside your browser
# tab" 17 px at y=104, centred on a 480x270 transparent canvas. Then:
#   ffmpeg -f lavfi -i "gradients=size=480x270:rate=24:speed=0.012:nb_colors=4:\
#     c0=0x1d3557:c1=0x457b9d:c2=0xe63946:c3=0xf4a261:duration=20" \
#     -f lavfi -i "testsrc2=size=160x90:rate=24:duration=20" -i title.png \
#     -f lavfi -i "aevalsrc=exprs='ARP+0.07*sin(2*PI*110*t)+TICK|ARP*0.8+0.07*sin(2*PI*110.5*t)+TICK':s=48000:d=20" \
#     -filter_complex "[0][1]overlay=x='(W-w)/2+130*sin(t*0.9)':y=H-h-22[a];\
#       [a][2]overlay=0:0,format=yuv420p[v]" -map "[v]" -map 3:a -t 20 \
#     -c:v libx264 -profile:v baseline -level 3.0 -preset slow -crf 23 -g 48 \
#     -c:a aac -b:a 128k -ar 48000 -ac 2 -movflags +faststart sample.mp4
#   ARP  = 0.16*sin(2*PI*220*pow(2,floor(2.5*mod(floor(t*4),5)+0.5)/12)*t)*exp(-12*mod(t,0.25))
#   TICK = 0.30*sin(2*PI*1500*t)*exp(-70*mod(t,1))   (a tick on every whole second —
#          compare it with the test card's timecode to judge A/V sync)
# (baseline profile: no CABAC/B-frames, the cheapest H.264 to decode).
NAME="lotplay"
VERSION="1.1.0-r1"   # r1: relinked on the binary128 long-double libc (exact printf rounding)
                  # 1.1.0: sound (aac/mp3/vorbis/opus/flac/ac3 → xtiny's sound socket)
DESCRIPTION="Video player for the X desktop (ffmpeg decode, with sound via xtiny) — Apps menu → Videos"
FFMPEG_UPSTREAM="5.1.6"
SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_UPSTREAM}.tar.gz"
SOURCE_SHA256=""
DEPENDS="xtiny"

build() {
    . "$RECIPES_DIR/_webdeps.sh"
    webdeps_env
    $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/wasm_dlmalloc.c" -o "$WEBDEPS_OBJS/wasm_dlmalloc.o"
    export LOT_LINK_OBJS="$WEBDEPS_OBJS/wasm_dlmalloc.o $WEBDEPS_OBJS/wasm_ld128.o"
    NM=$(find /nix/store -maxdepth 3 -name "llvm-nm" -path "*llvm-19*" 2>/dev/null | sort | head -1)
    [ -x "$NM" ] || NM=nm

    # ── ffmpeg libraries, video only ─────────────────────────────────────
    cd "$SRC"
    FFPREFIX="/tmp/lot-build/lotplay-ffmpeg-2"   # bump when the component set changes
    if [ ! -f "$FFPREFIX/lib/libavcodec.a" ]; then
        ./configure \
            --prefix="$FFPREFIX" \
            --enable-cross-compile --target-os=linux --arch=generic \
            --cc="$LOTCC" --host-cc=cc --ar="$WEBDEPS_AR" --ranlib="$RANLIB" --nm="$NM" --strip=true \
            --pkg-config=false \
            --extra-cflags="$CFLAGS -D_GNU_SOURCE" \
            --disable-asm --disable-x86asm \
            --disable-pthreads --disable-w32threads --disable-os2threads \
            --disable-autodetect --disable-doc --disable-debug \
            --disable-shared --enable-static --disable-programs \
            --disable-everything \
            --disable-avdevice --disable-avfilter --disable-postproc --disable-network \
            --enable-swresample \
            --enable-decoder=h264,hevc,mpeg4,mpeg1video,mpeg2video,vp8,vp9,theora,mjpeg,h263,msmpeg4v3,flv,vp6f \
            --enable-decoder=aac,aac_latm,mp3,mp3float,mp2,vorbis,opus,flac,ac3,eac3,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_f32le,pcm_u8 \
            --enable-demuxer=mov,matroska,avi,mpegts,mpegps,ogg,flv,ivf,h264,hevc,m4v,mjpeg,mpegvideo \
            --enable-demuxer=mp3,aac,wav,flac,ac3 \
            --enable-parser=h264,hevc,mpeg4video,mpegvideo,vp8,vp9,mjpeg,h263,vp3 \
            --enable-parser=aac,aac_latm,mpegaudio,vorbis,opus,flac,ac3 \
            --enable-protocol=file,pipe \
            || { echo "==> configure failed; ffbuild/config.log tail:"; tail -40 ffbuild/config.log; exit 1; }
        make -j8 > make.log 2>&1 || { tail -30 make.log; exit 1; }
        make install > install.log 2>&1 || { tail -30 install.log; exit 1; }
    fi

    # ── X libraries from our own packages ─────────────────────────────────
    XDEPS="/tmp/lot-build/lotplay-xdeps"
    rm -rf "$XDEPS" && mkdir -p "$XDEPS"
    for p in libX11 libxcb libXau libXdmcp xorgproto; do
        t=$(ls "$REPO_ROOT"/packages/$p-*.tar.gz 2>/dev/null | head -1)
        [ -n "$t" ] || { echo "missing package tarball: $p" >&2; exit 1; }
        tar xzf "$t" -C "$XDEPS"
    done
    XINC=""; XLIB=""
    for d in "$XDEPS"/pkg-*/usr; do
        [ -d "$d/include" ] && XINC="$XINC -I$d/include"
        [ -d "$d/lib" ] && XLIB="$XLIB -L$d/lib"
    done
    # the reduced libX11 leaves these i18n hooks undefined (as for wolf3d)
    cat > "$SRC/lotplay_compat.c" <<'COMPAT'
void *_Xi18n_lock = 0;
void *_conv_lock = 0;
void *_XrmInitParseInfo(void *statep) { if (statep) *(void **)statep = 0; return 0; }
COMPAT

    # ── the player ────────────────────────────────────────────────────────
    $CC $CFLAGS -O2 -D_GNU_SOURCE -I"$FFPREFIX/include" $XINC \
        -c "$REPO_ROOT/lotplay.c" -o "$SRC/lotplay.o" || { echo "lotplay.c compile failed" >&2; exit 1; }
    $CC $CFLAGS -c "$SRC/lotplay_compat.c" -o "$SRC/lotplay_compat.o"
    $CC $CFLAGS -o "$SRC/lotplay" "$SRC/lotplay.o" "$SRC/lotplay_compat.o" \
        "$WEBDEPS_OBJS/wasm_dlmalloc.o" "$WEBDEPS_OBJS/wasm_ld128.o" \
        $LDFLAGS -Wl,-z,stack-size=8388608 -L"$FFPREFIX/lib" $XLIB \
        -lavformat -lavcodec -lswscale -lswresample -lavutil -lX11 -lxcb -lXau \
        $CRT1 -lc -lm $BUILTINS \
        || { echo "lotplay link failed" >&2; exit 1; }

    mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/local/share/lotplay" "$STAGE/usr/share/applications"
    install -m755 "$SRC/lotplay" "$STAGE/usr/local/bin/lotplay"
    install -m644 "$REPO_ROOT/packages/media/lotplay-sample.mp4" "$STAGE/usr/local/share/lotplay/sample.mp4"
    cat > "$STAGE/usr/share/applications/lotplay.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Videos
Comment=Video player with sound (ffmpeg)
Exec=lotplay
Terminal=false
X-LinuxOnTab-Package=lotplay
X-LinuxOnTab-Color=#E63946
DESKTOP
    rmdir "$STAGE/bin" 2>/dev/null || true
}

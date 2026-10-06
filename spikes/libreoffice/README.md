# Spike: LibreOffice compiled natively to the wasm kernel

Goal: LibreOffice (26.8) as a native wasm32 program on the LinuxOnTab kernel,
GUI through the VCL X11 backend on xtiny.

## Toolchain: C++ exceptions (done)

LibreOffice needs C++ exceptions everywhere. `toolchain/cpp-eh-sysroot`
(built by `toolchain/build-cpp-eh-sysroot.sh`) is the musl sysroot plus
libc++/libc++abi/libunwind compiled with `-fwasm-exceptions`; the older
`cpp-sysroot-fixed` cannot throw. `local/cpp-eh/ehtest` checks it in the
guest (8/8). Modules that use exceptions must not be asyncified, so
LibreOffice runs without fork (posix_spawn only).

## Build host

LibreOffice cross-builds need a Linux build machine (configure builds the
tools the build runs, natively). `Dockerfile` here: Debian trixie with
clang/lld 19.1.7, the same version as the host toolchain.

    docker build -t lot-libreoffice-build spikes/libreoffice
    docker volume create lo-work      # source + build tree live in the volume
    docker run --rm -u 0 -v lo-work:/work -v <dir with tarball>:/dl:ro lot-libreoffice-build \
      sh -c 'cd /work && tar xJf /dl/libreoffice-26.8.1.1.tar.xz && chown -R lo /work'

Docker Hub pulls hang on this machine; the base image comes from
public.ecr.aws.

## Plan

1. configure + gbuild: a new host, Linux on CPU wasm32 (`--disable-dynamic-loading`,
   bundled externals), gbuild platform derived from `EMSCRIPTEN_INTEL_GCC.mk`.
2. wasm setjmp/longjmp runtime; UNO bridge from `bridges/source/cpp_uno/gcc3_wasm`
   (replace `EM_JS jsGetExportedSymbol` with a generated table).
3. headless `soffice --convert-to` in the guest.
4. VCL gen (X11) on xtiny — xtiny is core protocol only, so cairo/VCL must use
   their no-RENDER paths.

All four steps work (2026-10-06): `soffice.bin --version`, headless
`--convert-to pdf`, and Writer on xtiny (>= 1.9.0) with menus and dialogs.

## The guest disk

    sh spikes/libreoffice/make-image.sh        # -> shell/linux-dist/libreoffice.ext4 (~295 MB)
    cd cloudflare && IMAGE=libreoffice.ext4 GZIP=1 ./upload-rootfs.sh

The console's "libreoffice" row boots the lean image with that disk
(`?xdisk=linux-dist/libreoffice.ext4&x`) and runs
`mount ... /opt/lo && /opt/lo/lo-desktop`: xtiny, then Writer. In any guest
with the disk mounted at /opt/lo:

    /opt/lo/writer [file]                      # Writer on DISPLAY :1 (also Apps → Writer)
    /opt/lo/soffice --headless --convert-to pdf --outdir /tmp /tmp/notes.txt

Wasm-specific changes worth knowing (edit-tree.py has the details): osl
threads get 4 MB stacks (musl's 128 KB default overflowed silently), the
shared comphelper::ThreadPool runs tasks inline (a lost wakeup hung dialogs),
the module URL comes from /proc/self/exe (no dladdr), and the final link
needs wasm-ld >= 20 (19 bound a global to a same-named static elsewhere).

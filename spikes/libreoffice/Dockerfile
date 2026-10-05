# Build host for the LibreOffice -> wasm32 (LinuxOnTab kernel) port.
# LibreOffice cross-builds need a Linux build machine: configure runs a
# nested native build of the tools it executes during the build (idlc,
# cppumaker, gendict, ...). Debian trixie's clang/lld are 19.1.7, the same
# version as the host toolchain that built toolchain/cpp-eh-sysroot.
FROM public.ecr.aws/docker/library/debian:trixie-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential clang-19 lld-19 llvm-19 \
      autoconf automake libtool pkg-config bison flex gperf nasm \
      make perl python3 python3-dev zip unzip xz-utils bzip2 ca-certificates curl git \
      libxml2-utils xsltproc libxml2-dev libxslt1-dev \
      libfontconfig-dev libfreetype-dev libharfbuzz-dev libcairo2-dev \
      libnss3-dev libcups2-dev libssl-dev zlib1g-dev libexpat1-dev \
      libjpeg-dev libpng-dev libicu-dev libboost-dev libltdl-dev \
      libx11-dev libxext-dev libxrender-dev libxrandr-dev libxinerama-dev libxt-dev \
      libkrb5-dev ccache rsync file wabt binaryen procps \
 && rm -rf /var/lib/apt/lists/*
# the build side builds harfbuzz with meson + ninja
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ninja-build meson \
 && rm -rf /var/lib/apt/lists/*
RUN for t in clang clang++ lld wasm-ld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip; do \
      ln -sf /usr/bin/$t-19 /usr/local/bin/$t 2>/dev/null || true; done; \
    ln -sf /usr/lib/llvm-19/bin/wasm-ld /usr/local/bin/wasm-ld
RUN useradd -m -u 501 lo
USER lo
WORKDIR /work

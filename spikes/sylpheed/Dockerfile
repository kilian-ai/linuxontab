# The LibreOffice build image (spikes/libreoffice/Dockerfile: clang/lld 19,
# wasm-ld 20, meson, the wasm-cc driver mounted from the repo) plus the
# native tools a GTK 2 cross build runs on the build machine.
#   docker build -t lot-gtk-build spikes/sylpheed
FROM lot-libreoffice-build
USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libglib2.0-dev-bin libgdk-pixbuf2.0-bin gtk-update-icon-cache gettext python3-packaging \
 && rm -rf /var/lib/apt/lists/*
# wasm-cc links with wasm-ld 20 (see spikes/libreoffice/Dockerfile); images
# built before that line was added lack it
RUN [ -x /usr/lib/llvm-20/bin/wasm-ld ] || { mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/llvm.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/llvm.asc] http://apt.llvm.org/trixie/ llvm-toolchain-trixie-20 main" \
      > /etc/apt/sources.list.d/llvm20.list \
 && apt-get update && apt-get install -y --no-install-recommends lld-20 \
 && rm -rf /var/lib/apt/lists/*; }
USER lo
WORKDIR /work

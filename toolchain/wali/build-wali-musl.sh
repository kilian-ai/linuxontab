#!/usr/bin/env bash
# Build wali-musl (the LP64-on-wasm32 musl with wali.SYS_* syscall imports)
# that Rust's wasm32-wali-linux-musl target links against. Produces a sysroot
# at $WALI_SYSROOT (default /tmp/wali-sysroot): libc.a + crt1-command.o + headers.
#
# Requires clang 22 with the `wasm32-unknown-linux-muslwali` target (the triple
# that makes `long` 64-bit on wasm32 — added in LLVM 22). Neither our clang-19
# nor clang-21 has it; we fetch the stock LLVM 22.1.3 release WALI pins.
set -e
WALI_SYSROOT="${WALI_SYSROOT:-/tmp/wali-sysroot}"
LLVM_DIR="${LLVM_DIR:-/tmp/llvm22}"
WALI_SRC="${WALI_SRC:-/tmp/WALI}"
LLVM_VER=22.1.3

# 1. LLVM 22 (macOS ARM64 shown; adjust asset for your platform)
if [ ! -x "$LLVM_DIR/bin/clang" ]; then
  echo "==> Fetching LLVM $LLVM_VER"
  curl -L --fail -o /tmp/llvm22.tar.xz \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VER/LLVM-$LLVM_VER-macOS-ARM64.tar.xz"
  mkdir -p "$LLVM_DIR"; tar -xf /tmp/llvm22.tar.xz -C "$LLVM_DIR" --strip-components=1
fi
"$LLVM_DIR/bin/clang" --target=wasm32-linux-muslwali -dM -E - </dev/null 2>/dev/null | grep -q '__LONG_MAX__ 9223372036854775807' \
  && echo "==> clang-22 muslwali LP64 OK" || { echo "clang-22 lacks muslwali target"; exit 1; }

# 2. WALI repo + wali-musl submodule
if [ ! -d "$WALI_SRC/wali-musl/arch/wasm32" ]; then
  echo "==> Cloning WALI + wali-musl"
  git clone --depth 1 https://github.com/arjunr2/WALI.git "$WALI_SRC"
  git -C "$WALI_SRC" submodule update --init --depth 1 wali-musl
fi

# 3. Build wali-musl -> sysroot (WALI's musl_config equivalent)
cd "$WALI_SRC/wali-musl"
cat > config.mak <<EOF
SHARED_LIBS =
COMPILER_BIN = $LLVM_DIR/bin
AR = \$(COMPILER_BIN)/llvm-ar
RANLIB = \$(COMPILER_BIN)/llvm-ranlib
CC = \$(COMPILER_BIN)/clang
ARCH = wasm32
CROSS_COMPILE = llvm-
prefix = $WALI_SYSROOT
bindir = $WALI_SYSROOT/bin
EOF
make -j"$(sysctl -n hw.logicalcpu 2>/dev/null || nproc)" install

# 4. Add WALI's prebuilt compiler-rt builtins + a libunwind stub (panic=abort)
cp "$WALI_SRC/toolchains/rt_builtins/llvm-22.libclang_rt.builtins-wasm32-wali.a" \
   "$WALI_SYSROOT/lib/libclang_rt.builtins-wasm32-wali.a"
"$LLVM_DIR/bin/llvm-ar" crs "$WALI_SYSROOT/lib/libunwind.a"

echo "==> wali-musl sysroot ready at $WALI_SYSROOT"
echo "    Point the Rust build's link args at it (see cargo-config.reference.toml)."

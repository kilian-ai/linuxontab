#!/bin/sh
# Recipe: trust — TRUST, a retro DOS-style TUI IDE for Rust (ratatui + crossterm),
# github.com/wojtczyk/trust. The first RUST program packaged for the guest:
# built for wasm32-wali-linux-musl and run through the WALI bridge
# (shell/linux-dist/dist/wali-bridge.js). See toolchain/wali/README.md.
#
# Needs on the host: rust nightly + rust-src, the wali-musl sysroot
# (toolchain/wali/build-wali-musl.sh -> /tmp/wali-sysroot). The C toolchain
# variables build-package.sh sets are unused here.
#
# In the guest: cd into a directory and run `trust`. Its Cargo/rustc/lldb
# integrations shell out to tools that do not exist on the guest and report
# that in the IDE; editing, project browsing and saving work.

NAME="trust"
VERSION="0.1.0"
DESCRIPTION="TRUST — retro TUI IDE for Rust (ratatui), the guest's first Rust program"
# pinned commit (2026-09-08)
SOURCE_URL="https://github.com/wojtczyk/trust/archive/f559c74d4ddef1cc248615720cdd3d7bb6e2b6c4.tar.gz"
SOURCE_SHA256=""

build() {
    cd "$SRC"
    # raw module: build-package.sh asyncifies the staged binary itself
    WALI_NO_ASYNCIFY=1 "$REPO_ROOT/toolchain/wali/build-rust-crate.sh" "$SRC" "$SRC/trust-raw.wasm"
    mkdir -p "$STAGE/usr/local/bin"
    cp "$SRC/trust-raw.wasm" "$STAGE/usr/local/bin/trust"
    chmod 755 "$STAGE/usr/local/bin/trust"
}

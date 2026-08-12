#!/bin/sh
# push-wasm-pkg.sh — Build a WASM package and push it to a running WASM guest.
#
# Usage:
#   push-wasm-pkg.sh CODE BINARY_PATH [DEST_PATH]
#
#   CODE        — 4-char tunnel code printed by the running wasm.html page
#   BINARY_PATH — path to the WASM binary on Mac (already asyncified)
#   DEST_PATH   — destination path inside the guest (default: /usr/local/bin/<name>)
#
# Examples:
#   # Push a single binary to /usr/local/bin/
#   ./local/push-wasm-pkg.sh EJCY /tmp/mybinary.wasm
#
#   # Push to a specific path
#   ./local/push-wasm-pkg.sh EJCY /tmp/sqlite3.wasm /usr/local/bin/sqlite3
#
#   # Push a pre-built package tarball and register it with apk
#   ./local/push-wasm-pkg.sh EJCY --tarball packages/sqlite3-3.51.0.tar.gz
#
# Requirements on Mac:
#   brew install e2fsprogs binaryen
#   WASM binary must already be asyncified (wasm-opt --asyncify -O1 ...)
#   Tunnel listener is started automatically on port 2222.
#
# NOTE: Changes are session-only (lost on page reload). To persist, also copy
# files into rootfs/ and run ./build-rootfs.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH_PORT=2222
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

die()  { echo "push-wasm-pkg: error: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

[ -n "$1" ] || { echo "Usage: $0 CODE BINARY_PATH [DEST_PATH]"; echo "       $0 CODE --tarball PKG.tar.gz"; exit 1; }

CODE="$1"; shift

# Start tunnel listener in the background (idempotent — kills old one if running)
LISTENER_PID=""
cleanup() { [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

# Check if port 2222 is already listening (tunnel may already be up)
if ! lsof -i :$SSH_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    info "Starting tunnel listener for code $CODE on port $SSH_PORT..."
    sh "$SCRIPT_DIR/local/tunnel-listen.sh" "$CODE" "$SSH_PORT" 22 &
    LISTENER_PID=$!
    # Wait for listener to become ready
    for i in $(seq 1 15); do
        sleep 0.5
        lsof -i :$SSH_PORT -sTCP:LISTEN -t >/dev/null 2>&1 && break
        if [ "$i" = "15" ]; then
            die "Tunnel listener didn't start on port $SSH_PORT after 7.5s. Is code $CODE active?"
        fi
    done
    info "Tunnel ready."
else
    info "Port $SSH_PORT already listening, reusing existing tunnel."
fi

scp_send() {
    local src="$1" dst="$2"
    scp -P "$SSH_PORT" $SSH_OPTS "$src" "root@localhost:$dst"
}

ssh_run() {
    ssh -p "$SSH_PORT" $SSH_OPTS root@localhost "$@"
}

# ── Mode: --tarball ──────────────────────────────────────────────────────────
if [ "$1" = "--tarball" ]; then
    TARBALL="$2"
    [ -n "$TARBALL" ] || die "Usage: $0 CODE --tarball PKG.tar.gz"
    [ -f "$TARBALL" ] || die "Tarball not found: $TARBALL"

    TARNAME="$(basename "$TARBALL")"
    # Derive package name from tarball (e.g. sqlite3-3.51.0.tar.gz → sqlite3)
    PKGNAME="${TARNAME%%-[0-9]*}"

    info "Pushing tarball $TARNAME to guest /packages/..."
    scp_send "$TARBALL" "/packages/$TARNAME"

    # Also push the updated index.json if it exists
    INDEX="$SCRIPT_DIR/rootfs/packages/index.json"
    if [ -f "$INDEX" ]; then
        info "Updating /packages/index.json on guest..."
        scp_send "$INDEX" "/packages/index.json"
    fi

    info "Installing $PKGNAME via apk..."
    ssh_run "apk add $PKGNAME"
    info "Done. $PKGNAME installed in the running guest (session-only)."
    exit 0
fi

# ── Mode: single binary ──────────────────────────────────────────────────────
BINARY_PATH="$1"
[ -n "$BINARY_PATH" ] || die "Usage: $0 CODE BINARY_PATH [DEST_PATH]"
[ -f "$BINARY_PATH" ] || die "Binary not found: $BINARY_PATH"

# Verify it's a WASM file
if [ "$(head -c 4 "$BINARY_PATH" 2>/dev/null | od -An -tx1 | tr -d ' \n')" != "0061736d" ]; then
    die "$BINARY_PATH does not appear to be a WASM binary (missing \\0asm magic)"
fi

# Check for --import-memory (recommended but not required for simple binaries)
if command -v wasm-objdump >/dev/null 2>&1; then
    if ! wasm-objdump -x "$BINARY_PATH" 2>/dev/null | grep -q "Import.*memory\|env\.memory"; then
        echo "WARNING: $BINARY_PATH does not appear to import memory from the kernel."
        echo "         If it crashes with 'memory access out of bounds', rebuild with --import-memory."
    fi
fi

BINNAME="$(basename "$BINARY_PATH" .wasm)"
BINNAME="${BINNAME%.asyncified}"
DEST_PATH="${2:-/usr/local/bin/$BINNAME}"

info "Pushing $(basename "$BINARY_PATH") → guest:$DEST_PATH"
scp_send "$BINARY_PATH" "$DEST_PATH"
ssh_run "chmod +x '$DEST_PATH'"
info "Done. Run in guest: $DEST_PATH"
info "NOTE: This change is session-only. To persist, copy to rootfs/ and run ./build-rootfs.sh"

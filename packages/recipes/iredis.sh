#!/bin/sh
# Recipe: iredis — interactive Redis TUI client (syntax highlighting, live
# completion, human-readable replies) for the lean image, so `iredis` is one
# first-run away instead of a flaky in-guest pip install.
#
# Payload = pure-Python wheels unpacked into site-packages + a launcher.
# The wheels are host-downloaded, version-pinned to what iredis 1.15.2
# declares (redis<6, packaging<24, wcwidth==0.1.9), plus Pygments and click,
# which the python3 package does not ship. No pip in the guest: pip's install
# phase intermittently trips musl mallocng's get_meta assert in python3.11,
# and guest downloads from files.pythonhosted.org stall — see
# packages/iredis-src-1.15.2.tar.gz (built with COPYFILE_DISABLE=1).
#
#   iredis            # REPL against 127.0.0.1:6379 (start redis-server first)
#   iredis ping       # one-shot command

NAME="iredis"
VERSION="1.15.2"
DESCRIPTION="iredis — interactive Redis client with completion and syntax highlighting (needs redis-server)"
SOURCE_URL="file:///Users/kilian/.ai/LinuxOnTab-kernel/packages/iredis-src-1.15.2.tar.gz"
SOURCE_SHA256=""
DEPENDS="python3"

build() {
    SP="$STAGE/usr/local/lib/python3.11/site-packages"
    mkdir -p "$SP" "$STAGE/usr/local/bin"
    for w in "$SRC"/wheels/*.whl; do
        unzip -qo "$w" -d "$SP"
    done
    # Pre-bake the pycs on the host. The guest's first import otherwise
    # compiles ~1,100 modules and writes their __pycache__ to ext4, and that
    # first run reliably died in python3.11's mallocng get_meta trap (the
    # second run, with pycs on disk, was fine). unchecked-hash: the guest
    # never revalidates against source mtimes, which extraction rewrites.
    # -s/-p strip the stage prefix so co_filename is the guest path.
    HOSTPY="${LOT_HOST_PYTHON311:-/opt/homebrew/bin/python3.11}"
    "$HOSTPY" -c 'import sys; assert sys.version_info[:2]==(3,11), sys.version' || {
        echo "iredis: need a host python3.11 (same pyc magic as the guest): set LOT_HOST_PYTHON311" >&2; exit 1; }
    "$HOSTPY" -m compileall -q --invalidation-mode unchecked-hash \
        -s "$STAGE" -p / "$SP" || { echo "iredis: compileall failed" >&2; exit 1; }
    # Console script from iredis's entry_points: iredis = iredis.entry:main
    cat > "$STAGE/usr/local/bin/iredis" <<'LAUNCHER'
#!/bin/sh
exec python3 -c 'from iredis.entry import main; main()' "$@"
LAUNCHER
    chmod 755 "$STAGE/usr/local/bin/iredis"
    rmdir "$STAGE/bin" 2>/dev/null || true
}

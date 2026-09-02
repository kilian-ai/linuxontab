#!/bin/sh
# Pack the guest-side Spiel tree (rootfs/opt/{webfuse,webfuse-libs,frontend} +
# the spiel-demo launcher) into packages/spiel-src-2.0.tar.gz for recipes/spiel.sh.
set -e
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/spiel/opt" "$T/spiel/usr/local/bin"
cp -Rp "$R/rootfs/opt/webfuse" "$R/rootfs/opt/webfuse-libs" "$R/rootfs/opt/frontend" "$T/spiel/opt/"
rm -rf "$T/spiel/opt/webfuse/data/"* "$T/spiel/opt/webfuse/__pycache__"
cp -p "$R/rootfs/usr/local/bin/spiel-demo" "$T/spiel/usr/local/bin/"
mkdir -p "$T/spiel/etc/nginx" && cp -p "$R/rootfs/etc/nginx/spiel.conf" "$T/spiel/etc/nginx/"
COPYFILE_DISABLE=1 tar czf "$R/packages/spiel-src-2.0.tar.gz" -C "$T" spiel
ls -la "$R/packages/spiel-src-2.0.tar.gz"

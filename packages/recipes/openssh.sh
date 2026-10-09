#!/bin/sh
# Recipe: openssh — the OpenSSH 9.9p2 server (sshd, sshd-session, sftp-server)
# for the lean image, which ships without it. The binaries are the ones the
# full image runs (rootfs/, built by local/rebuild-sshd-wasm.sh, already
# asyncified). Built without OpenSSL, so ssh-ed25519 only. Config, the sshd
# privsep user and root's shadow entry are already in the lean image's /etc.
#
#   apk add openssh     # then the top bar's "remote" button (it can also
#                       # install and start sshd itself)
#
# No auto-install stubs (cloudflare/build-lean-rootfs.sh SKIP_PKGS): a stub at
# /sbin/sshd would make /etc/rc "start sshd" — i.e. download this package —
# on every lean boot. With a persisted disk (?persist=1) rc starts an installed
# sshd at boot; otherwise the remote button reinstalls it after a reload.

NAME="openssh"
VERSION="9.9p2-r0"
DESCRIPTION="OpenSSH server (sshd + sftp-server, ed25519 only): ssh/sftp into this tab via the remote button"
SOURCE_URL="local:"
NO_ASYNCIFY=1   # rootfs/ binaries are already asyncified

build() {
    mkdir -p "$STAGE/sbin" "$STAGE/usr/local/libexec"
    cp "$REPO_ROOT/rootfs/sbin/sshd" "$STAGE/sbin/sshd"
    cp "$REPO_ROOT/rootfs/usr/local/libexec/sshd-session" "$STAGE/usr/local/libexec/sshd-session"
    cp "$REPO_ROOT/rootfs/usr/local/libexec/sftp-server" "$STAGE/usr/local/libexec/sftp-server"
    chmod 755 "$STAGE/sbin/sshd" "$STAGE/usr/local/libexec/sshd-session" "$STAGE/usr/local/libexec/sftp-server"
}

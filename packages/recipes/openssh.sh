#!/bin/sh
# Recipe: openssh — the OpenSSH 9.9p2 server (sshd, sshd-session, sftp-server)
# for the lean image, which ships without it, and the source of the full
# image's copies in rootfs/. Built without OpenSSL, so ssh-ed25519 only.
# Config, the sshd privsep user and root's shadow entry are already in /etc.
#
#   apk add openssh     # then the top bar's "remote" button (it can also
#                       # install and start sshd itself)
#
# r1 builds from source on the current sysroot. r0 shipped the rootfs/
# binaries: an sshd from local/rebuild-sshd-wasm.sh on an older sysroot and an
# sshd-session from the first port. That sshd-session used musl's mallocng,
# whose large-block path needs mmap and traps on wasm. A fast client lets
# SSH's output buffer pass 128 KB, so every download over ~0.6-2 MB (cat, scp,
# SFTP get) killed the session.
#
# No auto-install stubs (cloudflare/build-lean-rootfs.sh SKIP_PKGS): a stub at
# /sbin/sshd would make /etc/rc "start sshd" — i.e. download this package —
# on every lean boot. With a persisted disk (?persist=1) rc starts an installed
# sshd at boot; otherwise the remote button reinstalls it after a reload.

NAME="openssh"
VERSION="9.9p2-r1"
DESCRIPTION="OpenSSH server (sshd + sftp-server, ed25519 only): ssh/sftp into this tab via the remote button"
SOURCE_URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p2.tar.gz"
SOURCE_SHA256="91aadb603e08cc285eddf965e1199d02585fa94d994d6cae5b41e1721e215673"

ZLIB_VER="1.3.1"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
ZLIB_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"

build() {
    # ── zlib (static, built once) ───────────────────────────────────────────
    ZL="/tmp/lot-build/zlib-$ZLIB_VER-wasm"
    if [ ! -f "$ZL/.built" ]; then
        A="/tmp/lot-src-zlib-$ZLIB_VER.tar.gz"
        [ -f "$A" ] || curl -sL --fail -o "$A" "$ZLIB_URL" || { echo "zlib download failed" >&2; exit 1; }
        [ "$(shasum -a 256 "$A" | cut -d' ' -f1)" = "$ZLIB_SHA256" ] || { echo "zlib checksum mismatch" >&2; exit 1; }
        rm -rf "$SRC/zlib" && mkdir -p "$SRC/zlib" && tar xzf "$A" -C "$SRC/zlib" --strip-components=1
        ( cd "$SRC/zlib" \
          && CC="$CC" CFLAGS="$CFLAGS" AR="$AR" RANLIB="$RANLIB" CHOST=wasm32-unknown-linux-musl \
               ./configure --static --prefix="$ZL" > configure.log 2>&1 \
          && make -j8 libz.a > make.log 2>&1 ) || { echo "zlib build failed" >&2; exit 1; }
        rm -rf "$ZL" && mkdir -p "$ZL/lib" "$ZL/include"
        cp "$SRC/zlib/libz.a" "$ZL/lib/" && cp "$SRC/zlib/zlib.h" "$SRC/zlib/zconf.h" "$ZL/include/"
        touch "$ZL/.built"
    fi

    # ── shims ────────────────────────────────────────────────────────────────
    # dlmalloc: sbrk-only malloc, so SSH buffers past 128 KB don't hit
    # mallocng's mmap path. wasm_fork: fork() through the kernel's asyncify
    # thunk (sshd forks sshd-session per connection; the session forks the
    # privsep child and the user's shell or sftp-server).
    SHIMS=""
    for f in wasm_dlmalloc wasm_fork; do
        $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/$f.c" -o "$SRC/lot-$f.o"
        SHIMS="$SHIMS $SRC/lot-$f.o"
    done
    # the sysroot's unistd.h leaves fork() undeclared for wasm. No includes
    # here (pid_t is int): <sys/types.h> would drag in select(), which
    # smult_curve25519_ref.c defines as a static helper of its own.
    printf 'int fork(void);\n' > "$SRC/lot-fork-decls.h"

    # sshkey.c keeps decrypted key material in an mmap(MAP_ANON) region it
    # madvise()s out of core dumps. There is no mmap here: use the heap.
    python3 - sshkey.c <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
new = """static int
sshkey_prekey_alloc(u_char **prekeyp, size_t len)
{
	u_char *prekey;

	*prekeyp = NULL;
	if ((prekey = calloc(1, len)) == NULL)
		return SSH_ERR_ALLOC_FAIL;
	*prekeyp = prekey;
	return 0;
}

static void
sshkey_prekey_free(void *prekey, size_t len)
{
	freezero(prekey, len);
}
"""
pat = re.compile(r"static int\nsshkey_prekey_alloc\(u_char \*\*prekeyp, size_t len\)\n\{.*?\n\}\n\nstatic void\nsshkey_prekey_free\(void \*prekey, size_t len\)\n\{.*?\n\}\n", re.S)
s, n = pat.subn(lambda m: new, s)
assert n == 1, "sshkey_prekey_alloc anchor"
open(p, "w").write(s)
PY

    # misc.c lib_contains_symbol() mmap()s a file to search it: read it instead.
    python3 - misc.c <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old_map = """	if ((m = mmap(NULL, sz, PROT_READ, MAP_PRIVATE, fd, 0)) == MAP_FAILED ||
	    m == NULL) {
		error_f("mmap %s: %s", path, strerror(errno));
		goto out;
	}"""
new_map = """	if ((m = malloc(sz)) == NULL || atomicio(read, fd, m, sz) != sz) {
		error_f("read %s: %s", path, strerror(errno));
		goto out;
	}"""
old_unmap = """	if (m != NULL && m != MAP_FAILED)
		munmap(m, sz);"""
new_unmap = """	free(m);"""
assert s.count(old_map) == 1 and s.count(old_unmap) == 1, "misc.c mmap anchors"
s = s.replace(old_map, new_map).replace(old_unmap, new_unmap)
if '#include "atomicio.h"' not in s:
    s = s.replace('#include "misc.h"', '#include "misc.h"\n#include "atomicio.h"', 1)
open(p, "w").write(s)
PY

    # ── openssh ─────────────────────────────────────────────────────────────
    # lot-cc.sh puts the full wasm link line on every link step, so configure's
    # link probes and the Makefile's three programs all link the same way.
    export LOT_CLANG_BIN="$CLANG" LOT_SYSROOT_DIR="$SYSROOT" LOT_CRT1="$CRT1" LOT_BUILTINS="$BUILTINS"
    export LOT_LDFLAGS="$LDFLAGS -Wl,-z,stack-size=1048576"
    export LOT_LINK_OBJS="$SHIMS"
    export LOT_LINK_LIBS=""
    CC="$REPO_ROOT/sysroot/lot-cc.sh" \
    CFLAGS="$CFLAGS -include $SRC/lot-fork-decls.h" \
    LDFLAGS="" AR="$AR" RANLIB="$RANLIB" \
    ./configure \
        --host=wasm32-unknown-linux-musl \
        --prefix=/usr \
        --sysconfdir=/etc/ssh \
        --libexecdir=/usr/local/libexec \
        --with-pid-dir=/run \
        --disable-security-key \
        --disable-strip \
        --with-zlib="$ZL" \
        --without-zlib-version-check \
        --without-openssl \
        --without-pam \
        --without-kerberos5 \
        > "$SRC/openssh-configure.log" 2>&1 \
        || { echo "openssh configure failed" >&2; tail -30 "$SRC/openssh-configure.log" >&2; exit 1; }

    make -j8 sshd sshd-session sftp-server > "$SRC/openssh-make.log" 2>&1 \
        || { echo "openssh build failed" >&2; grep -m20 -B2 -A6 "error" "$SRC/openssh-make.log" >&2; exit 1; }

    mkdir -p "$STAGE/sbin" "$STAGE/usr/local/libexec"
    install -m755 sshd "$STAGE/sbin/sshd"
    install -m755 sshd-session sftp-server "$STAGE/usr/local/libexec/"
}

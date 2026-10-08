#!/bin/sh
# Recipe: neomutt — lean terminal mail client (IMAP/POP/SMTP over TLS).
#
#   neomutt                      # reads ~/.config/neomutt/neomuttrc
#
# On the X desktop it runs in an xterm (xtiny Apps menu: "Mail"). Mail goes
# straight from the guest to the provider over the WISP relay (IMAPS 993,
# SMTPS 465 / submission 587); no local MTA. TLS is OpenSSL 1.1.1w against
# the guest's CA bundle (/etc/ssl/cert.pem), built once into $OSSL with the
# same configuration as the curl, netsurf and python3 recipes. IMAP/SMTP
# authentication uses NeoMutt's built-in PLAIN/LOGIN/OAUTHBEARER (no SASL
# library): Gmail/Outlook/Fastmail work with an app password.
#
# The package ships a commented starter config at /etc/neomuttrc.example and
# a first-run helper (neomutt-setup) that writes ~/.config/neomutt/neomuttrc.
#
# Platform shims: dlmalloc (mallocng's >128 KB path traps without mmap; big
# mails and IMAP buffers hit it) and the asyncify fork thunk (neomutt forks
# for $editor, pipes and sendmail). The sysroot's libc does binary128 long
# double itself since 7ccde12f, so the wasm_ld128 compat object is gone.

NAME="neomutt"
NEOMUTT_TAG="20260616"
VERSION="${NEOMUTT_TAG}-r2"   # r2: page-aligned brk (b6fd3d53); r1: binary128 long-double libc (7ccde12f)
DESCRIPTION="NeoMutt mail client (IMAP, POP, SMTP over TLS)"
SOURCE_URL="https://github.com/neomutt/neomutt/archive/refs/tags/${NEOMUTT_TAG}.tar.gz"
SOURCE_SHA256="2c34fdd2166d5765e6bfdc21d1248bc4e92ddc0a33537b9418c17cd90e2dda80"
DEPENDS=""

OPENSSL_VER="1.1.1w"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz"
OPENSSL_SHA256="cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"
NCURSES_VER="6.5"
NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz"

build() {
    # ── 1. OpenSSL (shared with curl/netsurf/python3) ───────────────────────
    OSSL="/tmp/lot-build/openssl-$OPENSSL_VER-wasm"
    if [ ! -f "$OSSL/.built" ]; then
        A="/tmp/lot-src-openssl-$OPENSSL_VER.tar.gz"
        [ -f "$A" ] || curl -sL --fail -o "$A" "$OPENSSL_URL" || { echo "openssl download failed" >&2; exit 1; }
        [ "$(shasum -a 256 "$A" | cut -d' ' -f1)" = "$OPENSSL_SHA256" ] || { echo "openssl checksum mismatch" >&2; exit 1; }
        rm -rf "$SRC/openssl" && mkdir -p "$SRC/openssl" && tar xzf "$A" -C "$SRC/openssl" --strip-components=1
        ( cd "$SRC/openssl" \
          && CC="$CC" AR="$AR" RANLIB="$RANLIB" ./Configure linux-generic32 no-asm no-shared no-dso no-engine \
                no-async no-tests no-ui-console -DOPENSSL_NO_SECURE_MEMORY \
                no-bf no-cast no-idea no-rc2 no-rc4 no-rc5 no-md2 no-md4 no-mdc2 \
                no-seed no-camellia no-whirlpool no-blake2 \
                -DOPENSSL_DEV_NO_ATOMICS -D__STDC_NO_ATOMICS__=1 --prefix="$OSSL" $CFLAGS > configure.log 2>&1 \
          && make -j8 build_libs > make.log 2>&1 ) || { echo "openssl build failed" >&2; exit 1; }
        rm -rf "$OSSL" && mkdir -p "$OSSL/lib" "$OSSL/include"
        cp "$SRC"/openssl/libssl.a "$SRC"/openssl/libcrypto.a "$OSSL/lib/"
        cp -R "$SRC/openssl/include/openssl" "$OSSL/include/"
        touch "$OSSL/.built"
    fi

    # ── 2. ncursesw (same configuration as mc/nano/tmux) ────────────────────
    NC="/tmp/lot-build/ncursesw-$NCURSES_VER-wasm"
    if [ ! -f "$NC/.built" ]; then
        A="/tmp/lot-src-ncurses-$NCURSES_VER.tar.gz"
        [ -f "$A" ] || curl -sL --fail -o "$A" "$NCURSES_URL" || { echo "ncurses download failed" >&2; exit 1; }
        rm -rf "$SRC/ncurses" && mkdir -p "$SRC/ncurses" && tar xzf "$A" -C "$SRC/ncurses" --strip-components=1
        ( cd "$SRC/ncurses" \
          && ./configure --host=wasm32-unknown-linux-musl --prefix=/usr \
                --without-shared --without-progs --without-manpages \
                --without-pkg-config --without-tests --without-cxx \
                --without-cxx-binding --without-ada --with-normal \
                --enable-widec --enable-overwrite \
                --with-default-terminfo-dir=/usr/share/terminfo \
                --with-terminfo-dirs=/usr/share/terminfo:/lib/terminfo:/etc/terminfo \
                CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="-nostdlib" \
                LIBS="$CRT1 -lc $BUILTINS" AR="$AR" RANLIB="$RANLIB" \
                BUILD_CC="$(command -v gcc || command -v cc)" > configure.log 2>&1 \
          && make -j8 > make.log 2>&1 \
          && rm -rf "$NC" && make DESTDIR="$NC" install.libs install.includes > install.log 2>&1 ) \
          || { echo "ncurses build failed" >&2; exit 1; }
        touch "$NC/.built"
    fi

    # ── 3. shims ─────────────────────────────────────────────────────────────
    SHIMS=""
    for f in wasm_dlmalloc wasm_fork; do
        $CC $CFLAGS -w -c "$REPO_ROOT/sysroot/$f.c" -o "$SRC/lot-$f.o"
        SHIMS="$SHIMS $SRC/lot-$f.o"
    done
    printf '#include <sys/types.h>\npid_t fork(void);\npid_t vfork(void);\n' > "$SRC/lot-fork-decls.h"

    # ── 4. neomutt ───────────────────────────────────────────────────────────
    # autosetup only compiles and links its probes, so the lot-cc.sh wrapper
    # (full wasm link line on every link step) makes them answer for wasm32.
    export LOT_CLANG_BIN="$CLANG" LOT_SYSROOT_DIR="$SYSROOT" LOT_CRT1="$CRT1" LOT_BUILTINS="$BUILTINS"
    export LOT_LDFLAGS="$LDFLAGS -Wl,-z,stack-size=1048576"
    export LOT_LINK_OBJS="$SHIMS"
    export LOT_LINK_LIBS="-L$OSSL/lib -lssl -lcrypto"
    cd "$SRC"
    # OpenSSL's default verify paths point into its build prefix here; also
    # trust the guest's CA bundle (curl gets the same via --with-ca-bundle)
    python3 - conn/openssl.c <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = r"""      mutt_debug(LL_DEBUG1, "Error setting default verify paths\n");
      goto free_ctx;
    }
"""
new = old + r"""    /* LinuxOnTab: the guest's CA bundle */
    SSL_CTX_load_verify_locations(sockdata(conn)->sctx, "/etc/ssl/cert.pem", NULL);
"""
assert s.count(old) == 1, "openssl.c anchor"
open(p, "w").write(s.replace(old, new))
PY
    # wasm32 crt1 only calls main() or main(argc, argv): take envp from environ
    python3 - main.c <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "int main(int argc, char *argv[], char *envp[])\n{\n"
new = "extern char **environ;\nint main(int argc, char *argv[])\n{\n  char **envp = environ;\n"
assert s.count(old) == 1, "main.c anchor"
open(p, "w").write(s.replace(old, new))
PY
    # declared int, defined void: a mismatched call traps on wasm
    sed -i.bak 's/^int index_adjust_sort_threads(/void index_adjust_sort_threads(/' index/private.h
    CC="$REPO_ROOT/sysroot/lot-cc.sh" \
    CFLAGS="$CFLAGS -D_GNU_SOURCE -include $SRC/lot-fork-decls.h -I$OSSL/include" \
    LDFLAGS="" \
    ./configure --host=wasm32-unknown-linux-musl --build="$(sh autosetup/autosetup-config.guess)" \
        --prefix=/usr --sysconfdir=/etc --sysroot="$SYSROOT" \
        --with-ncurses="$NC/usr" \
        --ssl --with-ssl="$OSSL" \
        --disable-nls --disable-idn2 --disable-doc --disable-inotify \
        --disable-pgp --disable-smime \
        --with-lock=fcntl --with-mailpath=/var/mail \
        > "$SRC/neomutt-configure.log" 2>&1 \
        || { echo "neomutt configure failed" >&2; tail -30 "$SRC/neomutt-configure.log" >&2; exit 1; }
    make -j8 neomutt > "$SRC/neomutt-make.log" 2>&1 \
        || { echo "neomutt build failed" >&2; grep -m20 -B2 -A6 "error" "$SRC/neomutt-make.log" >&2; exit 1; }
    install -Dm755 neomutt "$STAGE/bin/neomutt"

    # ── 5. system defaults, first-run helper, desktop entry ─────────────────
    install -d "$STAGE/etc" "$STAGE/usr/share/applications"
    cat > "$STAGE/etc/neomuttrc" <<'RC'
# /etc/neomuttrc — LinuxOnTab defaults, read before ~/.config/neomutt/neomuttrc
# (neomutt-setup writes that one for you).
set ssl_force_tls = yes            # never send a password in the clear
set ssl_use_system_certs = yes     # /etc/ssl/cert.pem
set message_cachedir = "~/.cache/neomutt/bodies"
set mail_check = 120               # IMAP: poll the inbox every 2 minutes
set imap_keepalive = 240
set timeout = 30
set beep = no
set charset = "utf-8"
set send_charset = "us-ascii:utf-8"
set use_threads = threads
set sort = last-date
set sort_aux = date
set index_format = "%4C %Z %{%b %d} %-18.18L %s"
set pager_index_lines = 6
set pager_stop = yes
set markers = no
set editor = "vi"

# show the headers people read, in this order
ignore *
unignore from: to: cc: date: subject: reply-to:
hdr_order from: to: cc: date: subject:

# a quiet palette for xterm on xtiny (8 colours)
color normal      default      default
color indicator   brightwhite  blue
color status      brightwhite  blue
color tree        cyan         default
color index       brightwhite  default  ~N
color index       red          default  ~D
color index       yellow       default  ~F
color hdrdefault  cyan         default
color header      brightyellow default  "^Subject:"
color quoted      green        default
color signature   brightblack  default
color attachment  yellow       default
color error       brightred    default
color message     brightgreen  default
RC

    cat > "$STAGE/bin/neomutt-setup" <<'SH'
#!/bin/sh
# neomutt-setup — write ~/.config/neomutt/neomuttrc for one IMAP/SMTP account.
#   neomutt-setup          ask, write the config (asks before replacing one)
#   neomutt-setup --run    only ask if there is no config yet, then start neomutt
cfgdir="$HOME/.config/neomutt"
cfg="$cfgdir/neomuttrc"
if [ "$1" = "--run" ]; then
    if [ -f "$cfg" ] || [ -f "$HOME/.neomuttrc" ] || [ -f "$HOME/.muttrc" ]; then
        exec neomutt
    fi
elif [ -f "$cfg" ]; then
    printf '%s exists. Replace it? [y/N] ' "$cfg"
    read -r ans
    case "$ans" in y|Y|yes) ;; *) exit 0 ;; esac
fi

echo "NeoMutt account setup (leave a field empty for the suggestion in [])."
echo "Gmail, Outlook, iCloud, Yahoo, Fastmail: use an app password."
echo
printf 'Email address: '; read -r email
case "$email" in *@*) ;; *) echo "not an email address"; exit 1 ;; esac
printf 'Your name: '; read -r realname
domain="${email#*@}"
imap="imap.$domain"; smtp="smtps://smtp.$domain:465"
case "$domain" in
    gmail.com|googlemail.com)
        imap="imap.gmail.com"; smtp="smtps://smtp.gmail.com:465" ;;
    outlook.com|hotmail.com|live.com|msn.com)
        imap="outlook.office365.com"; smtp="smtp://smtp-mail.outlook.com:587" ;;
    icloud.com|me.com|mac.com)
        imap="imap.mail.me.com"; smtp="smtp://smtp.mail.me.com:587" ;;
    yahoo.com|ymail.com)
        imap="imap.mail.yahoo.com"; smtp="smtps://smtp.mail.yahoo.com:465" ;;
    fastmail.com|fastmail.fm)
        imap="imap.fastmail.com"; smtp="smtps://smtp.fastmail.com:465" ;;
    posteo.de|posteo.net)
        imap="posteo.de"; smtp="smtp://posteo.de:587" ;;
    gmx.de|gmx.net|gmx.com)
        imap="imap.gmx.net"; smtp="smtps://mail.gmx.net:465" ;;
    web.de)
        imap="imap.web.de"; smtp="smtps://smtp.web.de:465" ;;
esac
printf 'IMAP server [%s]: ' "$imap"; read -r ans; [ -n "$ans" ] && imap="$ans"
printf 'SMTP URL [%s]: ' "$smtp"; read -r ans; [ -n "$ans" ] && smtp="$ans"
printf 'Login [%s]: ' "$email"; read -r user; [ -n "$user" ] || user="$email"
printf 'Save the password in the config (plain text)? [y/N] '; read -r savepw
pass=""
case "$savepw" in
    y|Y|yes)
        stty -echo 2>/dev/null
        printf 'Password: '; read -r pass
        stty echo 2>/dev/null; echo ;;
esac

sent="+Sent"; drafts="+Drafts"; trash="+Trash"
case "$imap" in
    imap.gmail.com)     # Gmail files sent mail itself
        sent=""; drafts="+[Gmail]/Drafts"; trash="+[Gmail]/Trash" ;;
esac

mkdir -p "$cfgdir" "$HOME/.cache/neomutt/bodies"
umask 077
{
    echo "# written by neomutt-setup; system defaults are in /etc/neomuttrc"
    echo "set from = \"$email\""
    [ -n "$realname" ] && echo "set real_name = \"$realname\""
    echo "set imap_user = \"$user\""
    echo "set smtp_user = \"$user\""
    if [ -n "$pass" ]; then
        echo "set imap_pass = \"$pass\""
        echo "set smtp_pass = \"$pass\""
    fi
    echo "set folder = \"imaps://$imap/\""
    echo "set spool_file = \"+INBOX\""
    echo "set record = \"$sent\""
    echo "set postponed = \"$drafts\""
    echo "set trash = \"$trash\""
    echo "set smtp_url = \"$smtp\""
    echo "mailboxes +INBOX"
} > "$cfg"
echo "Wrote $cfg"
[ "$1" = "--run" ] && exec neomutt
exit 0
SH
    chmod 755 "$STAGE/bin/neomutt-setup"

    # same id as xtiny's built-in "Mail" entry, so it looks the same before
    # and after install
    cat > "$STAGE/usr/share/applications/neomutt.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Mail
Comment=NeoMutt mail client (IMAP/SMTP)
Exec=neomutt-setup --run
Terminal=true
X-LinuxOnTab-Package=neomutt
DESKTOP

    TERMINFO_STAGE="$STAGE/usr/share/terminfo"
    mkdir -p "$TERMINFO_STAGE"
    for _t in xterm-256color xterm vt100 vt102; do
        /usr/bin/infocmp -x "$_t" 2>/dev/null | \
            /usr/bin/tic -x -o "$TERMINFO_STAGE" - 2>/dev/null || true
    done
    mkdir -p "$TERMINFO_STAGE/v" "$TERMINFO_STAGE/x"
    [ -f "$TERMINFO_STAGE/76/vt100" ] && cp -f "$TERMINFO_STAGE/76/vt100" "$TERMINFO_STAGE/v/vt100"
    [ -f "$TERMINFO_STAGE/76/vt102" ] && cp -f "$TERMINFO_STAGE/76/vt102" "$TERMINFO_STAGE/v/vt102"
    [ -f "$TERMINFO_STAGE/78/xterm" ] && cp -f "$TERMINFO_STAGE/78/xterm" "$TERMINFO_STAGE/x/xterm"
    [ -f "$TERMINFO_STAGE/78/xterm-256color" ] && cp -f "$TERMINFO_STAGE/78/xterm-256color" "$TERMINFO_STAGE/x/xterm-256color"
    rm -rf "$TERMINFO_STAGE/76" "$TERMINFO_STAGE/78"
}

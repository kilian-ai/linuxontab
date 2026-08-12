#!/bin/sh
# Recipe: nodejs — JavaScript runtime (QuickJS 2024-01-13) + npm
#
# Builds QuickJS as a wasm32-linux-musl binary, ships three things:
#
#   /bin/qjs                — QuickJS REPL/interpreter (asyncified WASM)
#   /usr/local/bin/node     — shell wrapper: fakes Node.js CLI, delegates to qjs
#   /usr/local/bin/npm      — minimal npm: install/run/init from registry
#
# Limitations vs real Node.js:
#   - No Node.js built-in modules (fs, http, path, crypto, ...)
#   - CommonJS require() is not available; use ES module import/export
#   - Worker threads disabled (pthreads not available in WASM kernel)
#   - npm install fetches pure-JS packages only; native addons will not work
#
# apk add curl — required for npm install (HTTPS to registry.npmjs.org)

NAME="nodejs"
VERSION="20.0.0"
DESCRIPTION="JavaScript runtime (QuickJS 2026-05-21, ES2023) + npm package manager"
# No release tags exist; pin to a specific commit.
# d73189dd = 2026-05-21 "fixed compilation with clang"
SOURCE_URL="https://github.com/bellard/quickjs/archive/d73189dd5a582c19c565774bd56fed4e72d33c99.tar.gz"
SOURCE_SHA256=""

build() {
    # ── Compile QuickJS ─────────────────────────────────────────────────────

    # CONFIG_WORKER=0 : disable pthread-based workers (pthreads not available)
    # _GNU_SOURCE      : unlocks some POSIX extensions used by quickjs-libc.c
    # CONFIG_VERSION   : version string embedded in the binary
    # JS_DEFAULT_STACK_SIZE: raise QuickJS JS stack from 256KB → 8MB so that
    #   require() can parse large npm packages (js-yaml, lodash, etc.) without
    #   a "SyntaxError: stack overflow" during recursive descent parsing.
    DEFS="-D_GNU_SOURCE -DCONFIG_WORKER=0 -DJS_DEFAULT_STACK_SIZE=8388608"

    # The Nix clang package ships without its own built-in headers (stripped
    # for size), so stdatomic.h is not available.  The musl sysroot also lacks
    # it.  Provide a minimal single-threaded stub.
    # CONFIG_VERSION written to header — shell quoting for -D"string" macros is fragile
    mkdir -p /tmp/lot-include
    printf '#define CONFIG_VERSION "2026-05-21"\n' > /tmp/lot-include/qjs-version.h
    cat > /tmp/lot-include/stdatomic.h << 'ATOMICEOF'
#ifndef _STDATOMIC_H
#define _STDATOMIC_H
/* Stub for single-threaded WASM — no real atomics needed */
#include <stdint.h>
#include <stddef.h>
#define _Atomic(T) T
typedef _Atomic(_Bool)              atomic_bool;
typedef _Atomic(char)               atomic_char;
typedef _Atomic(int)                atomic_int;
typedef _Atomic(unsigned int)       atomic_uint;
typedef _Atomic(long)               atomic_long;
typedef _Atomic(unsigned long)      atomic_ulong;
typedef _Atomic(long long)          atomic_llong;
typedef _Atomic(unsigned long long) atomic_ullong;
typedef _Atomic(intptr_t)           atomic_intptr_t;
typedef _Atomic(uintptr_t)          atomic_uintptr_t;
typedef _Atomic(size_t)             atomic_size_t;
typedef _Atomic(ptrdiff_t)          atomic_ptrdiff_t;
typedef enum memory_order {
    memory_order_relaxed, memory_order_consume, memory_order_acquire,
    memory_order_release, memory_order_acq_rel, memory_order_seq_cst
} memory_order;
#define ATOMIC_VAR_INIT(v)  (v)
#define atomic_init(p,v)    (void)(*(p) = (v))
#define atomic_load(p)                  (*(p))
#define atomic_load_explicit(p,o)       (*(p))
#define atomic_store(p,v)               (void)(*(p) = (v))
#define atomic_store_explicit(p,v,o)    (void)(*(p) = (v))
#define atomic_fetch_add(p,v)  ({ __typeof__(v) _o=*(p); *(p)+=(v); _o; })
#define atomic_fetch_add_explicit(p,v,o) atomic_fetch_add(p,v)
#define atomic_fetch_sub(p,v)  ({ __typeof__(v) _o=*(p); *(p)-=(v); _o; })
#define atomic_fetch_sub_explicit(p,v,o) atomic_fetch_sub(p,v)
#define atomic_fetch_or(p,v)   ({ __typeof__(v) _o=*(p); *(p)|=(v); _o; })
#define atomic_fetch_or_explicit(p,v,o)  atomic_fetch_or(p,v)
#define atomic_fetch_and(p,v)  ({ __typeof__(v) _o=*(p); *(p)&=(v); _o; })
#define atomic_fetch_and_explicit(p,v,o) atomic_fetch_and(p,v)
#define atomic_fetch_xor(p,v)  ({ __typeof__(v) _o=*(p); *(p)^=(v); _o; })
#define atomic_fetch_xor_explicit(p,v,o) atomic_fetch_xor(p,v)
#define atomic_exchange(p,v) \
    ({ __typeof__(v) _o=*(p); *(p)=(v); _o; })
#define atomic_exchange_explicit(p,v,o) atomic_exchange(p,v)
#define atomic_compare_exchange_strong(p,e,d) \
    ({ __typeof__(d) _e=*(e); \
       if(*(p)==_e){*(p)=(d);1;}else{*(e)=*(p);0;} })
#define atomic_compare_exchange_strong_explicit(p,e,d,s,f) \
    atomic_compare_exchange_strong(p,e,d)
#define atomic_compare_exchange_weak(p,e,d) \
    atomic_compare_exchange_strong(p,e,d)
#define atomic_compare_exchange_weak_explicit(p,e,d,s,f) \
    atomic_compare_exchange_strong(p,e,d)
#define atomic_thread_fence(o) ((void)0)
#define atomic_signal_fence(o) ((void)0)
#define atomic_is_lock_free(p) (sizeof(*(p)) <= sizeof(void*))
#define ATOMIC_BOOL_LOCK_FREE    2
#define ATOMIC_INT_LOCK_FREE     2
#define ATOMIC_LONG_LOCK_FREE    2
#define ATOMIC_LLONG_LOCK_FREE   2
#define ATOMIC_POINTER_LOCK_FREE 2
#endif /* _STDATOMIC_H */
ATOMICEOF
    # Single compat header to pull in everything quickjs needs that this sysroot
    # doesn't auto-include: config version, malloc_usable_size, fork, etc.
    cat > /tmp/lot-include/lot-compat.h << 'COMPATEOF'
#include <stddef.h>
#include <stdlib.h>
#include <malloc.h>
#include <sys/types.h>
#include <unistd.h>
/* musl guards fork/vfork behind #ifndef __wasm__; re-declare for WASM kernel */
#ifdef __wasm__
pid_t fork(void);
pid_t vfork(void);
#endif
COMPATEOF
    cat /tmp/lot-include/qjs-version.h >> /tmp/lot-include/lot-compat.h
    CFLAGS="-isystem /tmp/lot-include -include /tmp/lot-include/lot-compat.h $CFLAGS"

    # musl does not provide <execinfo.h> (backtrace is a glibc extension).
    # Provide no-op stubs so quickjs.c compiles cleanly.
    cat > wasm_stubs.c << 'STUBEOF'
#include <stddef.h>
int           backtrace(void **buf, int sz) { (void)buf; (void)sz; return 0; }
char        **backtrace_symbols(void *const *buf, int sz) { (void)buf; (void)sz; return NULL; }
void          backtrace_symbols_fd(void *const *buf, int sz, int fd) { (void)buf; (void)sz; (void)fd; }
STUBEOF

    # ── Build native qjsc to compile repl.js → repl.c ──────────────────────
    # qjsc must run on the host Mac; we use the system cc for this.
    echo "  CC (native) qjsc"
    cc -O2 -D_GNU_SOURCE -DCONFIG_VERSION='"2026-05-21"' -DCONFIG_WORKER=0 \
        cutils.c libregexp.c libunicode.c quickjs.c quickjs-libc.c dtoa.c qjsc.c \
        -o qjsc_native -lm
    echo "  QJSC repl.js"
    ./qjsc_native -c -o repl.c repl.js

    # ── Compile all sources for wasm32 ──────────────────────────────────────
    for src in quickjs.c libregexp.c libunicode.c cutils.c dtoa.c; do
        echo "  CC $src"
        $CC $CFLAGS $DEFS -c "$src" -o "${src%.c}.o"
    done

    echo "  CC quickjs-libc.c"
    $CC $CFLAGS $DEFS -c quickjs-libc.c -o quickjs-libc.o

    echo "  CC qjs.c"
    $CC $CFLAGS $DEFS -c qjs.c -o qjs.o

    echo "  CC repl.c"
    $CC $CFLAGS $DEFS -c repl.c -o repl.o

    echo "  CC wasm_stubs.c"
    $CC $CFLAGS -c wasm_stubs.c -o wasm_stubs.o

    # wasm_fork.c provides fork()/vfork() via kernel asyncify syscall
    echo "  CC wasm_fork.c"
    $CC $CFLAGS -c "$REPO_ROOT/sysroot/wasm_fork.c" -o wasm_fork.o

    # Raise WASM linear-memory C stack from the wasm-ld default (~64KB) to 8MB.
    # QuickJS's recursive descent parser walks deeply into large module files;
    # without enough C stack the WASM worker crashes before QJS's own limit fires.
    # wasm-ld uses -z stack-size=N (not --stack-size).
    LDFLAGS="$LDFLAGS -Wl,-z,stack-size=8388608"

    echo "  LD qjs"
    $CC $LDFLAGS \
        quickjs.o libregexp.o libunicode.o cutils.o dtoa.o \
        quickjs-libc.o qjs.o repl.o wasm_stubs.o wasm_fork.o \
        $LIBS_TRAIL -o "$STAGE/bin/qjs"

    # ── node wrapper (shell script, no asyncify) ────────────────────────────
    mkdir -p "$STAGE/usr/local/bin"

    cat > "$STAGE/usr/local/bin/node" << 'NODEEOF'
#!/bin/sh
# node — QuickJS wrapper providing a Node.js-compatible CLI with CommonJS require().
# exec replaces this process so fork depth stays at 2.
case "$1" in
    --version|-v)
        echo "v20.0.0-quickjs-2024.01.13"
        exit 0
        ;;
    --help|-h)
        cat << 'HELPEOF'
Usage: node [options] [script.js] [arguments]

  node                 start interactive REPL
  node script.js       run a script
  node -e 'code'       evaluate inline code
  node --version       show version

Engine: QuickJS 2024-01-13 (ES2023, CommonJS require() supported)
HELPEOF
        exit 0
        ;;
esac

# CommonJS require() shim.
# qjs is invoked with --std so globalThis.std and globalThis.os are pre-populated.
# This runs as a -e global eval (not a module) so no import statements needed.
SHIM='
(function() {
  var _std = globalThis.std;
  var _os  = globalThis.os;
  var _cache = {};

  function _readFile(p) {
    var f = _std.open(p, "r");
    if (!f) return null;
    var s = f.readAsString();
    f.close();
    return s;
  }

  function _stat(p) { var r = _os.stat(p); return r[1] === 0 ? r[0] : null; }
  function _isFile(p) { var s = _stat(p); return s !== null && (s.mode & 0xF000) === 0x8000; }
  function _isDir(p)  { var s = _stat(p); return s !== null && (s.mode & 0xF000) === 0x4000; }

  function _normPath(p) {
    var a = p[0] === "/";
    var parts = p.split("/");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
      var s = parts[i];
      if (s === "" || s === ".") continue;
      if (s === "..") { if (out.length > 0) out.pop(); }
      else out.push(s);
    }
    return (a ? "/" : "") + out.join("/");
  }

  function _tryExt(p) {
    if (_isFile(p))         return p;
    if (_isFile(p+".js"))   return p+".js";
    if (_isFile(p+".json")) return p+".json";
    return null;
  }

  function _resolveDir(p) {
    var pj = _readFile(p+"/package.json");
    if (pj) {
      try {
        var main = JSON.parse(pj).main;
        if (main) {
          var mp = p+"/"+main;
          var r = _isFile(mp) ? mp : (_isFile(mp+".js") ? mp+".js" : null);
          if (r) return r;
        }
      } catch(e) {}
    }
    if (_isFile(p+"/index.js")) return p+"/index.js";
    if (_isFile(p+"/index.json")) return p+"/index.json";
    return null;
  }

  function _resolve(req, fromDir) {
    if (req[0] === "." || req[0] === "/") {
      var p = _normPath((req[0] === "/") ? req : fromDir+"/"+req);
      var r = _tryExt(p);
      if (r) return r;
      if (_isDir(p)) return _resolveDir(p);
      return null;
    }
    var dir = fromDir;
    for (;;) {
      var nm = dir+"/node_modules/"+req;
      if (_isDir(nm)) { var r2 = _resolveDir(nm); if (r2) return r2; }
      var r3 = _tryExt(nm);
      if (r3) return r3;
      var parent = dir.replace(/\/[^\/]*$/, "");
      if (parent === dir) break;
      dir = parent;
    }
    return null;
  }

  function _requireAbs(abs) {
    abs = _normPath(abs);
    if (_cache[abs]) return _cache[abs].exports;
    var src = _readFile(abs);
    if (src === null) throw new Error("Cannot find module: "+abs);
    var mod = { exports: {}, filename: abs, id: abs, loaded: false };
    _cache[abs] = mod;
    var dir = abs.replace(/\/[^\/]*$/, "");
    if (abs.slice(-5) === ".json") { mod.exports = JSON.parse(src); mod.loaded = true; return mod.exports; }
    var wrapped = "(function(require,module,exports,__filename,__dirname){\n"+src+"\n})";
    var fn = eval(wrapped);
    fn(function(r){ return _requireFrom(r, dir); }, mod, mod.exports, abs, dir);
    mod.loaded = true;
    return mod.exports;
  }

  function _readProcLine(path) {
    var f = _std.open(path, "r"); if (!f) return "";
    var s = f.readAsString(); f.close(); return s;
  }

  var _builtins = {
    "os": {
      hostname: function() {
        var s = _readProcLine("/proc/sys/kernel/hostname");
        return s.replace(/\s+$/, "") || "localhost";
      },
      platform: function() { return "linux"; },
      arch:     function() { return "wasm32"; },
      uptime:   function() {
        var s = _readProcLine("/proc/uptime");
        return parseFloat(s.split(" ")[0]) || 0;
      },
      freemem:  function() {
        var s = _readProcLine("/proc/meminfo");
        var m = s.match(/MemFree:\s+(\d+)/);
        return m ? parseInt(m[1]) * 1024 : 0;
      },
      totalmem: function() {
        var s = _readProcLine("/proc/meminfo");
        var m = s.match(/MemTotal:\s+(\d+)/);
        return m ? parseInt(m[1]) * 1024 : 0;
      },
      cpus:     function() { return []; },
      networkInterfaces: function() { return {}; },
      tmpdir:   function() { return "/tmp"; },
      homedir:  function() { return "/root"; },
      type:     function() { return "Linux"; },
      release:  function() { return "6.1.0"; },
      version:  function() { return "#1 WASM32"; },
      endianness: function() { return "LE"; },
      EOL: "\n",
    },
    "path": {
      sep: "/", delimiter: ":",
      join: function() {
        var parts = [].slice.call(arguments);
        return _normPath(parts.join("/")) || ".";
      },
      resolve: function() {
        var parts = [].slice.call(arguments);
        var p = parts[0][0] === "/" ? parts[0] : _cwd + "/" + parts[0];
        for (var i = 1; i < parts.length; i++) {
          p = parts[i][0] === "/" ? parts[i] : p + "/" + parts[i];
        }
        return _normPath(p) || "/";
      },
      dirname: function(p) { return p.replace(/\/[^\/]*$/, "") || "/"; },
      basename: function(p, ext) {
        var b = p.replace(/.*\//, "");
        return (ext && b.slice(-ext.length) === ext) ? b.slice(0, -ext.length) : b;
      },
      extname: function(p) { var m = p.match(/(\.[^.\/]*)$/); return m ? m[1] : ""; },
      isAbsolute: function(p) { return p[0] === "/"; },
      normalize: _normPath,
      relative: function(from, to) {
        var f = _normPath(from).split("/"); var t = _normPath(to).split("/");
        while (f.length && t.length && f[0] === t[0]) { f.shift(); t.shift(); }
        return f.map(function(){ return ".."; }).concat(t).join("/") || ".";
      },
    },
  };

  function _requireFrom(req, fromDir) {
    if (_builtins[req]) return _builtins[req];
    var abs = _resolve(req, fromDir);
    if (!abs) throw new Error("Cannot find module: "+req+" (from "+fromDir+")");
    return _requireAbs(abs);
  }

  var _cwdBuf = new ArrayBuffer(4096);
  var _cwdRes = _os.getcwd(_cwdBuf, 4096);
  var _cwdLen = Array.isArray(_cwdRes) ? _cwdRes[0] : _cwdRes;
  if (_cwdLen < 0) _cwdLen = 0;
  var _cwdArr = new Uint8Array(_cwdBuf, 0, _cwdLen);
  var _cwd = "";
  for (var _i = 0; _i < _cwdLen; _i++) {
    if (_cwdArr[_i] === 0) break;
    _cwd += String.fromCharCode(_cwdArr[_i]);
  }

  globalThis.require = function(r) { return _requireFrom(r, _cwd); };
  globalThis.require.resolve = function(r) {
    var abs = _resolve(r, _cwd);
    if (!abs) throw new Error("Cannot find module: "+r);
    return abs;
  };
  globalThis.module = { exports: {}, id: ".", loaded: false };
  globalThis.exports = globalThis.module.exports;
  globalThis.__filename = "";
  globalThis.__dirname = _cwd;

  globalThis.process = {
    argv: (typeof scriptArgs !== "undefined") ? ["node"].concat(scriptArgs.slice(0)) : ["node"],
    env: {},
    exit: function(c){ _std.exit(c||0); },
    cwd: function(){ return _cwd; },
    version: "v20.0.0",
    versions: { node: "20.0.0", v8: "11.3.244.8" },
    platform: "linux",
    arch: "wasm32",
    stdout: { write: function(s){ _std.out.puts(s); } },
    stderr: { write: function(s){ _std.err.puts(s); } },
    hrtime: function(){ var t = _os.now(); return [Math.floor(t/1000)|0, ((t%1000)*1e6)|0]; },
  };

  function _fmt(x) {
    if (x === null) return "null";
    if (x === undefined) return "undefined";
    if (typeof x === "object") { try { return JSON.stringify(x, null, 2); } catch(e) { return String(x); } }
    return String(x);
  }
  globalThis.console = {
    log:   function(){ _std.out.puts([].slice.call(arguments).map(_fmt).join(" ")+"\n"); },
    error: function(){ _std.err.puts([].slice.call(arguments).map(_fmt).join(" ")+"\n"); },
    warn:  function(){ _std.err.puts("[warn] "+[].slice.call(arguments).map(_fmt).join(" ")+"\n"); },
    info:  function(){ _std.out.puts([].slice.call(arguments).map(_fmt).join(" ")+"\n"); },
    dir:   function(x){ _std.out.puts(_fmt(x)+"\n"); },
  };

  globalThis.setTimeout  = function(fn){ fn(); return 0; };
  globalThis.clearTimeout  = function(){};
  globalThis.setInterval   = function(){ return 0; };
  globalThis.clearInterval = function(){};
  globalThis.global = globalThis;
})();
'

if [ $# -eq 0 ]; then
    exec qjs --std
fi

case "$1" in
    -e|--eval)
        shift
        # qjs only honours the last -e flag; concatenate shim + user code.
        exec qjs --std -e "${SHIM}
${1}"
        ;;
    -*)
        exec qjs --std -e "$SHIM" "$@"
        ;;
    *)
        _script="$1"; shift
        case "$_script" in
            /*) _abs="$_script" ;;
            *)  _abs="$PWD/$_script" ;;
        esac
        # Concatenate shim + require call into a single -e argument.
        exec qjs --std -e "${SHIM}
require('${_abs}');" -- "$@"
        ;;
esac
NODEEOF
    chmod +x "$STAGE/usr/local/bin/node"

    # ── npm (shell script, no asyncify) ────────────────────────────────────
    # Fork-depth budget: shell(1) → npm(2) → subprocess(3, limit).
    # Never use $(...) inside npm (that nests forks); always use redirect+read.
    cat > "$STAGE/usr/local/bin/npm" << 'NPMEOF'
#!/bin/sh
# npm — minimal npm client for LinuxOnTab WASM guest
# Fork-depth-safe: npm runs at depth 2; all subprocesses run at depth 3.
# Never nest $(...) calls — use redirect-and-read pattern throughout.

NPM_VERSION="10.0.0-linuxontab"
REGISTRY="https://registry.npmjs.org"

_die()  { printf 'npm error: %s\n' "$*" >&2; exit 1; }
_log()  { printf 'npm: %s\n' "$*"; }

# HTTP GET $1 to file $2. curl preferred, then wget, then python3.
# python3 matters: neither curl nor busybox wget is in the base image, but
# python3 is — and it does real HTTPS (openssl + /etc/ssl/cert.pem), so npm
# works out of the box instead of failing with "apk add curl for HTTPS".
_get() {
    # Try each transport and FALL THROUGH ON FAILURE (not merely when the
    # command is missing): the shipped curl/wget exist but their socket path
    # times out in this guest (curl exit 28 even on plain HTTP), while
    # python3's urllib works. Success = downloaded file exists and is non-empty.
    rm -f "$2"
    if command -v curl >/dev/null 2>&1; then
        curl -sL --max-time 120 "$1" -o "$2" 2>/dev/null
        [ -s "$2" ] && return 0
    fi
    rm -f "$2"
    wget -qO "$2" "$1" 2>/dev/null
    [ -s "$2" ] && return 0
    rm -f "$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$1" "$2" <<'PYEOF'
import sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "npm-linuxontab"})
# Long timeout: the guest's inbound path is slow (tens of KB/s).
with urllib.request.urlopen(req, timeout=300) as r, open(sys.argv[2], "wb") as f:
    while True:
        chunk = r.read(65536)
        if not chunk:
            break
        f.write(chunk)
PYEOF
        [ -s "$2" ] && return 0
    fi
    return 1
}

# Extract dist.tarball URL from npm registry JSON (awk at depth 3).
# Writes the URL to $2 (temp file). Uses redirect pattern, no $().
_reg_tarball() {
    awk '/"tarball":/ {
        s=$0
        sub(/.*"tarball":[[:space:]]*"/, "", s)
        sub(/".*/, "", s)
        print s; exit
    }' "$1" > "$2"
}

# Extract first "version" value from JSON file. Writes to $2.
_reg_version() {
    awk '/"version":/ {
        s=$0
        sub(/.*"version":[[:space:]]*"/, "", s)
        sub(/".*/, "", s)
        print s; exit
    }' "$1" > "$2"
}

# Extract a named script from package.json scripts section. Writes cmd to $2.
_pkg_script() {
    awk -v sc="$1" '
        /"scripts":[[:space:]]*\{/ { in_s=1; next }
        in_s && /^[[:space:]]*\}/ { exit }
        in_s && index($0, "\"" sc "\":") > 0 {
            s=$0
            sub(/.*"[^"]*":[[:space:]]*"/, "", s)
            sub(/".*/, "", s)
            print s; exit
        }
    ' package.json > "$2"
}

# Install one package by name and optional version.
_install_one() {
    local pkg="$1" ver="$2"
    local endpoint tmpjson tmptar tmpout tarurl pkgver workdir
    tmpjson="/tmp/npm-meta-$$.json"
    tmptar="/tmp/npm-dl-$$.tgz"
    tmpout="/tmp/npm-out-$$"

    endpoint="$REGISTRY/$pkg/latest"
    [ -n "$ver" ] && endpoint="$REGISTRY/$pkg/$ver"

    _log "Fetching $pkg metadata..."
    _get "$endpoint" "$tmpjson" || _die "fetch failed for $pkg (apk add curl for HTTPS)"
    [ -s "$tmpjson" ] || _die "empty registry response for $pkg"

    # Tarball URL — awk writes to file, read picks it up (no $() nesting)
    _reg_tarball "$tmpjson" "$tmpout"
    read -r tarurl < "$tmpout" || tarurl=""
    rm -f "$tmpout"
    [ -n "$tarurl" ] || _die "no tarball URL in registry response for $pkg"

    _reg_version "$tmpjson" "$tmpout"
    read -r pkgver < "$tmpout" || pkgver="?"
    rm -f "$tmpout"
    rm -f "$tmpjson"

    _log "Downloading $pkg@$pkgver..."
    _get "$tarurl" "$tmptar" || _die "download failed for $pkg"
    [ -s "$tmptar" ] || _die "empty download for $pkg"

    mkdir -p "./node_modules"
    workdir="/tmp/npm-work-$$-$pkg"
    rm -rf "$workdir" && mkdir "$workdir"
    tar xzf "$tmptar" -C "$workdir" 2>/dev/null || _die "extract failed for $pkg"
    rm -f "$tmptar"

    # npm tarballs extract to a "package/" subdirectory
    rm -rf "./node_modules/$pkg"
    if [ -d "$workdir/package" ]; then
        mv "$workdir/package" "./node_modules/$pkg"
    else
        mv "$workdir" "./node_modules/$pkg"
        workdir=""
    fi
    [ -n "$workdir" ] && rm -rf "$workdir"

    _log "Installed $pkg@$pkgver → ./node_modules/$pkg"
}

cmd_install() {
    local pkg pname pver depfile
    if [ -z "$*" ]; then
        # No args: install from package.json dependencies
        [ -f package.json ] || _die "no package.json found — run: npm init"
        _log "Installing dependencies from package.json..."
        depfile="/tmp/npm-deps-$$"
        awk '
            /"dependencies":[[:space:]]*\{/ { in_d=1; next }
            in_d && /^[[:space:]]*\}/ { exit }
            in_d && /"[^"]+":/ {
                s=$0
                sub(/^[[:space:]]*"/, "", s)
                sub(/".*/, "", s)
                print s
            }
        ' package.json > "$depfile"
        while IFS= read -r dep; do
            [ -n "$dep" ] && _install_one "$dep" ""
        done < "$depfile"
        rm -f "$depfile"
    else
        for pkg in "$@"; do
            # Skip npm flags
            case "$pkg" in
                --save|--save-dev|--save-exact|--no-save|-S|-D|-E|-P) continue ;;
            esac
            pver=""
            case "$pkg" in
                *@*) pname="${pkg%%@*}"; pver="${pkg##*@}" ;;
                *)   pname="$pkg" ;;
            esac
            _install_one "$pname" "$pver"
        done
    fi
}

cmd_run() {
    local script="$1" tmpout cmd
    [ -n "$script" ] || _die "Usage: npm run <script>"
    [ -f package.json ] || _die "no package.json found"
    tmpout="/tmp/npm-sc-$$"
    _pkg_script "$script" "$tmpout"
    read -r cmd < "$tmpout" || cmd=""
    rm -f "$tmpout"
    [ -n "$cmd" ] || _die "script '$script' not found in package.json"
    _log "Running: $cmd"
    exec sh -c "$cmd"
}

cmd_init() {
    local force=0
    [ "$1" = "-y" ] || [ "$1" = "--yes" ] && force=1
    [ -f package.json ] && [ "$force" -eq 0 ] && \
        _die "package.json already exists (use npm init -y to overwrite)"
    # Use parameter expansion — no subprocess fork for basename
    local pkgname="${PWD##*/}"
    cat > package.json << PKGJSON
{
  "name": "$pkgname",
  "version": "1.0.0",
  "description": "",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "test": "echo \"no tests\" && exit 1"
  },
  "dependencies": {}
}
PKGJSON
    _log "Created package.json for $pkgname"
}

case "$1" in
    install|i)             shift; cmd_install "$@" ;;
    run)                   shift; cmd_run "$@" ;;
    start)                 cmd_run "start" ;;
    init)                  shift; cmd_init "$@" ;;
    version|--version|-v)  printf '%s\n' "$NPM_VERSION" ;;
    help|--help|-h|"")
        cat << 'HELPEOF'
Usage: npm <command>

Commands:
  install [pkg[@ver]]  install package(s) from npm registry
  install              install all deps listed in package.json
  run <script>         run a script defined in package.json
  start                run the "start" script
  init [-y]            create a package.json in the current directory
  version              show npm version

Engine: QuickJS 2024-01-13 (ES2023)
Note:   apk add curl   — needed for HTTPS access to registry.npmjs.org
        Only pure-JS packages work; native addons (.node files) will not run.
HELPEOF
        ;;
    *)  _die "unknown command: $1 — run 'npm help'" ;;
esac
NPMEOF
    chmod +x "$STAGE/usr/local/bin/npm"
}

# Teach configure.ac the LinuxOnTab target: Linux on CPU wasm32.
p='/work/libreoffice-26.8.1.1/configure.ac'; s=open(p).read()
def rep(old,new):
    global s
    assert old in s, old[:80]
    s=s.replace(old,new,1)
rep("""    if test "$enable_fuzzers" = yes; then
        test_system_freetype=no
    fi
    _os=Linux
    ;;""","""    if test "$enable_fuzzers" = yes; then
        test_system_freetype=no
    fi
    if test "$host_cpu" = wasm32; then
        # Linux on WebAssembly (the LinuxOnTab kernel): one statically
        # linked module, no dlopen, no fork; X11 through the guest's server.
        usable_dlapi=no
        build_skia=no
        test_gdb_index=no
        test_split_debug=no
        test_system_freetype=no
        enable_compiler_plugins=no
        enable_customtarget_components=yes
        with_system_zlib=no
    fi
    _os=Linux
    ;;""")
rep("""if test $_os = iOS -o $_os = Android -o $_os = Emscripten; then
    # Disable dynamic_loading always for iOS and Android""","""if test $_os = iOS -o $_os = Android -o $_os = Emscripten -o "$host_cpu" = wasm32; then
    # Disable dynamic_loading always for iOS, Android and WebAssembly""")
rep("""    OS=LINUX
    RTL_OS=Linux
    P_SEP=:

    case "$host_cpu" in
""","""    OS=LINUX
    RTL_OS=Linux
    P_SEP=:

    case "$host_cpu" in

    wasm32)
        CPUNAME=WASM32
        RTL_ARCH=WASM32
        PLATFORMID=linux_wasm32
        ;;
""")
rep("""    if test "$_os" = "Emscripten"; then
        sub_conf_opts="$sub_conf_opts --without-system-libxml""","""    if test "$_os" = "Emscripten" -o "$host_cpu" = wasm32; then
        sub_conf_opts="$sub_conf_opts --without-system-libxml""")
# a BUILD_TYPE marker the build side can see (BUILD_TYPE_FOR_HOST): it builds
# wasmbridgegen for this host, as it does for Emscripten
rep("""AC_SUBST(DISABLE_DYNLOADING)
""","""AC_SUBST(DISABLE_DYNLOADING)

if test "$host_cpu" = wasm32 -a "$_os" = Linux; then
    BUILD_TYPE="$BUILD_TYPE WASM32_LINUX"
fi
""")
# static-only X libraries (wasm32 has no shared objects at all)
rep("""        if echo $host_cpu | $GREP -E 'i[[3456]]86' 2>/dev/null >/dev/null; then""",
    """        if echo $host_cpu | $GREP -E 'i[[3456]]86|wasm32' 2>/dev/null >/dev/null; then""")
open(p,'w').write(s)
print("configure.ac: ok")

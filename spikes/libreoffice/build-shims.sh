#!/bin/sh
# Objects every LibreOffice wasm link pulls in (see bin/wasm-cc). In the container:
#   sh /lot/spike/build-shims.sh   -> /work/shims
set -eu
SYSROOT=/lot/toolchain/cpp-eh-sysroot; OUT=/work/shims; mkdir -p $OUT
CC="clang --target=wasm32-unknown-unknown --sysroot=$SYSROOT -O2 -matomics -mbulk-memory -fwasm-exceptions"
$CC -w -c /lot/sysroot/wasm_clone.c -o $OUT/wasm_clone.o
$CC -w -c /lot/sysroot/wasm_dlmalloc_mt.c -o $OUT/wasm_dlmalloc_mt.o
$CC -c /lot/sysroot/wasm_mmap.c -o $OUT/wasm_mmap.o
# the musl sysroot's long double is ld80-shaped, clang's is binary128:
# printf("%g") recursed forever in frexpl without these overrides
$CC -c /lot/sysroot/wasm_ld128.c -o $OUT/wasm_ld128.o
# fork() that fails with ENOSYS (no asyncify with C++ exceptions); weak-ish:
# it lives in an archive, so programs linking wasm_fork.o get the real one
$CC -c /lot/sysroot/wasm_fork_enosys.c -o $OUT/wasm_fork_enosys.o
llvm-ar rcs $OUT/libforkenosys.a $OUT/wasm_fork_enosys.o
$CC -c /lot/sysroot/wasm_syscall_cp.c -o $OUT/wasm_syscall_cp.o
$CC -c /lot/sysroot/wasm_cxa_thread_atexit.c -o $OUT/wasm_cxa_thread_atexit.o
$CC -mllvm -wasm-enable-sjlj -c /lot/sysroot/sjlj_rt_wasmeh.c -o $OUT/sjlj_rt.o
# worker.ts keeps the module's declared maximum memory only if it exports this
printf '__attribute__((export_name("__lot_big_memory"))) void __lot_big_memory(void) {}\n' > $OUT/lot_big_memory.c
$CC -c $OUT/lot_big_memory.c -o $OUT/lot_big_memory.o
# the symbols our reduced libX11 omits (xlibi18n, input methods), for X11 links
if [ -d /work/xprefix/lib ]; then
  $CC -c /lot/spike/xfe/x11_compat.c -o $OUT/x11_compat.o
  $CC -I/work/xprefix/include -c /lot/spike/xfe/x11_im_compat.c -o $OUT/x11_im_compat.o
  rm -f /work/xprefix/lib/libX11compat.a
  llvm-ar rcs /work/xprefix/lib/libX11compat.a $OUT/x11_compat.o $OUT/x11_im_compat.o
fi
ls -l $OUT/*.o

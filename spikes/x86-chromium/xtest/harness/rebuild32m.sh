set -e
apk add -q build-base git python3 linux-headers zlib-dev procps >/dev/null 2>&1
cd /w/nm && cc -O2 -w -c lot_mmap.c -o lot_mmap.o
cd /w/blink && ./configure CFLAGS="-O2 -DLOT_SYSCALLS -DLOT_FORCE_32BIT_HOST -include /w/nm/lot_redirect.h" >/w/configure.log 2>&1
make -j8 o//blink/blink.a o//blink/blink.o >/w/make.log 2>&1 || { grep -E "error" /w/make.log | head; exit 1; }
cc -static o//blink/blink.o o//blink/blink.a /w/nm/lot_mmap.o -lm -lpthread -o /w/bl/blink32m
ls -la /w/bl/blink32m

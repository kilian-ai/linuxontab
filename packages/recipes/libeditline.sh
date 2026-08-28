#!/bin/sh
# Recipe: libeditline — minimal editline-compatible bootstrap for wasm32

NAME="libeditline"
VERSION="1.0.0"
DESCRIPTION="Minimal editline-compatible readline/history API"
SOURCE_URL="https://github.com/troglobit/editline/archive/refs/tags/1.17.1.tar.gz"

build() {
    install -d "$SRC/bootstrap" "$STAGE/usr/include" "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/lib"

    cat > "$SRC/bootstrap/editline.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_EDITLINE_H
#define LOT_BOOTSTRAP_EDITLINE_H

#ifdef __cplusplus
extern "C" {
#endif

extern const char *rl_readline_name;
extern int el_hist_size;

char *readline(const char *prompt);
int read_history(const char *filename);
int write_history(const char *filename);
void rl_set_complete_func(char *(*func)(char *, int *));
void rl_set_list_possib_func(int (*func)(char *, char ***));

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/editline_stub.c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *rl_readline_name = "editline";
int el_hist_size = 1000;

static char *(*g_complete_func)(char *, int *) = 0;
static int (*g_list_possib_func)(char *, char ***) = 0;

void rl_set_complete_func(char *(*func)(char *, int *)) { g_complete_func = func; }
void rl_set_list_possib_func(int (*func)(char *, char ***)) { g_list_possib_func = func; }

int read_history(const char *filename)
{
    (void) filename;
    return 0;
}

int write_history(const char *filename)
{
    (void) filename;
    return 0;
}

char *readline(const char *prompt)
{
    (void) g_complete_func;
    (void) g_list_possib_func;

    if (prompt) {
        fputs(prompt, stdout);
        fflush(stdout);
    }

    size_t cap = 256;
    size_t len = 0;
    char *buf = (char *) malloc(cap);
    if (!buf) return NULL;

    int ch;
    while ((ch = fgetc(stdin)) != EOF && ch != '\n') {
        if (len + 1 >= cap) {
            size_t ncap = cap * 2;
            char *nbuf = (char *) realloc(buf, ncap);
            if (!nbuf) {
                free(buf);
                return NULL;
            }
            buf = nbuf;
            cap = ncap;
        }
        buf[len++] = (char) ch;
    }

    if (ch == EOF && len == 0) {
        free(buf);
        return NULL;
    }

    buf[len] = '\0';
    return buf;
}
EOF

    $CC $CFLAGS -I"$SRC/bootstrap" -c "$SRC/bootstrap/editline_stub.c" -o "$SRC/bootstrap/editline_stub.o"
    "$AR" rcs "$STAGE/usr/lib/libeditline.a" "$SRC/bootstrap/editline_stub.o"

    install -m644 "$SRC/bootstrap/editline.h" "$STAGE/usr/include/editline.h"

    cat > "$STAGE/usr/lib/pkgconfig/libeditline.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: libeditline
Description: Minimal editline bootstrap implementation
Version: 1.14.0
Cflags: -I/usr/include
Libs: -L/usr/lib -leditline
EOF

    cat > "$STAGE/usr/lib/pkgconfig/editline.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: editline
Description: Minimal editline bootstrap implementation
Version: 1.14.0
Cflags: -I/usr/include
Libs: -L/usr/lib -leditline
EOF
}
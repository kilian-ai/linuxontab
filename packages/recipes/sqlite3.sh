#!/bin/sh
# Recipe: sqlite3 - minimal SQLite C API compatibility shim for wasm32

NAME="sqlite3"
VERSION="0.1.0"
DESCRIPTION="Minimal sqlite3 compatibility shim"
SOURCE_URL="https://www.sqlite.org/2025/sqlite-autoconf-3510000.tar.gz"

build() {
    install -d "$SRC/bootstrap" "$STAGE/usr/include" "$STAGE/usr/lib" "$STAGE/usr/lib/pkgconfig"

    cat > "$SRC/bootstrap/sqlite3.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_SQLITE3_H
#define LOT_BOOTSTRAP_SQLITE3_H

#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef long long sqlite3_int64;
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef int (*sqlite3_callback)(void*,int,char**,char**);
typedef void (*sqlite3_destructor_type)(void*);

struct sqlite3 {
    sqlite3_int64 last_rowid;
    int changes;
    int errcode;
    int exterr;
    const char *errmsg;
};

struct sqlite3_stmt {
    sqlite3 *db;
    int state;
};

#define SQLITE_OK 0
#define SQLITE_ERROR 1
#define SQLITE_INTERNAL 2
#define SQLITE_PERM 3
#define SQLITE_ABORT 4
#define SQLITE_BUSY 5
#define SQLITE_PROTOCOL 15
#define SQLITE_ROW 100
#define SQLITE_DONE 101
#define SQLITE_NULL 5

#define SQLITE_OPEN_READONLY 0x00000001
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE 0x00000004
#define SQLITE_OPEN_URI 0x00000040

#define SQLITE_FCNTL_PERSIST_WAL 10

#define SQLITE_TRANSIENT ((sqlite3_destructor_type)-1)

int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close(sqlite3 *);
int sqlite3_exec(sqlite3*, const char *sql, sqlite3_callback, void *, char **errmsg);
int sqlite3_changes(sqlite3*);
int sqlite3_file_control(sqlite3*, const char *zDbName, int op, void *);
const char *sqlite3_errstr(int);
int sqlite3_errcode(sqlite3*);
int sqlite3_extended_errcode(sqlite3*);
int sqlite3_error_offset(sqlite3*);
const char *sqlite3_db_filename(sqlite3*, const char *zDbName);
const char *sqlite3_errmsg(sqlite3*);
int sqlite3_busy_timeout(sqlite3*, int ms);
void *sqlite3_trace(sqlite3*, void(*xTrace)(void*,const char*), void*);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3*);

int sqlite3_prepare_v2(sqlite3*, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_finalize(sqlite3_stmt *pStmt);
int sqlite3_reset(sqlite3_stmt *pStmt);
int sqlite3_step(sqlite3_stmt*);

int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int n, sqlite3_destructor_type);
int sqlite3_bind_blob(sqlite3_stmt*, int, const void*, int n, sqlite3_destructor_type);
int sqlite3_bind_int64(sqlite3_stmt*, int, sqlite3_int64);
int sqlite3_bind_null(sqlite3_stmt*, int);

const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt*, int iCol);
int sqlite3_column_type(sqlite3_stmt*, int iCol);
char *sqlite3_expanded_sql(sqlite3_stmt *pStmt);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/sqlite3_stub.c" << 'EOF'
#include <stdlib.h>
#include <string.h>

#include "sqlite3.h"

int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs)
{
    (void) filename;
    (void) flags;
    (void) zVfs;
    if (!ppDb) return SQLITE_ERROR;
    *ppDb = (sqlite3 *) calloc(1, sizeof(sqlite3));
    if (!*ppDb) return SQLITE_ERROR;
    (*ppDb)->errmsg = "sqlite3 stub";
    return SQLITE_OK;
}

int sqlite3_close(sqlite3 *db)
{
    free(db);
    return SQLITE_OK;
}

int sqlite3_exec(sqlite3 *db, const char *sql, sqlite3_callback cb, void *arg, char **errmsg)
{
    (void) sql;
    if (cb) (void) cb(arg, 0, NULL, NULL);
    if (errmsg) *errmsg = NULL;
    if (db) db->changes = 0;
    return SQLITE_OK;
}

int sqlite3_changes(sqlite3 *db) { return db ? db->changes : 0; }
int sqlite3_file_control(sqlite3 *db, const char *zDbName, int op, void *pArg)
{
    (void) db;
    (void) zDbName;
    (void) op;
    (void) pArg;
    return SQLITE_OK;
}

const char *sqlite3_errstr(int err)
{
    (void) err;
    return "sqlite3 stub";
}

int sqlite3_errcode(sqlite3 *db) { return db ? db->errcode : SQLITE_OK; }
int sqlite3_extended_errcode(sqlite3 *db) { return db ? db->exterr : SQLITE_OK; }
int sqlite3_error_offset(sqlite3 *db) { (void) db; return -1; }
const char *sqlite3_db_filename(sqlite3 *db, const char *zDbName) { (void) db; (void) zDbName; return ""; }
const char *sqlite3_errmsg(sqlite3 *db) { return db && db->errmsg ? db->errmsg : "sqlite3 stub"; }
int sqlite3_busy_timeout(sqlite3 *db, int ms) { (void) db; (void) ms; return SQLITE_OK; }
void *sqlite3_trace(sqlite3 *db, void(*xTrace)(void*,const char*), void *arg) { (void) db; (void) xTrace; (void) arg; return NULL; }
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3 *db) { return db ? db->last_rowid : 0; }

int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail)
{
    (void) zSql;
    (void) nByte;
    if (pzTail) *pzTail = NULL;
    if (!ppStmt) return SQLITE_ERROR;
    sqlite3_stmt *st = (sqlite3_stmt *) calloc(1, sizeof(sqlite3_stmt));
    if (!st) return SQLITE_ERROR;
    st->db = db;
    st->state = 0;
    *ppStmt = st;
    return SQLITE_OK;
}

int sqlite3_finalize(sqlite3_stmt *pStmt)
{
    free(pStmt);
    return SQLITE_OK;
}

int sqlite3_reset(sqlite3_stmt *pStmt)
{
    if (pStmt) pStmt->state = 0;
    return SQLITE_OK;
}

int sqlite3_step(sqlite3_stmt *pStmt)
{
    if (!pStmt) return SQLITE_ERROR;
    if (pStmt->state == 0) {
        pStmt->state = 1;
        return SQLITE_DONE;
    }
    return SQLITE_DONE;
}

int sqlite3_bind_text(sqlite3_stmt *s, int i, const char *v, int n, sqlite3_destructor_type d)
{ (void)s; (void)i; (void)v; (void)n; (void)d; return SQLITE_OK; }
int sqlite3_bind_blob(sqlite3_stmt *s, int i, const void *v, int n, sqlite3_destructor_type d)
{ (void)s; (void)i; (void)v; (void)n; (void)d; return SQLITE_OK; }
int sqlite3_bind_int64(sqlite3_stmt *s, int i, sqlite3_int64 v)
{ (void)s; (void)i; (void)v; return SQLITE_OK; }
int sqlite3_bind_null(sqlite3_stmt *s, int i)
{ (void)s; (void)i; return SQLITE_OK; }

const unsigned char *sqlite3_column_text(sqlite3_stmt *s, int c)
{ (void)s; (void)c; return (const unsigned char *) ""; }
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt *s, int c)
{ (void)s; (void)c; return 0; }
int sqlite3_column_type(sqlite3_stmt *s, int c)
{ (void)s; (void)c; return SQLITE_NULL; }

char *sqlite3_expanded_sql(sqlite3_stmt *pStmt)
{
    (void) pStmt;
    char *s = (char *) malloc(1);
    if (s) s[0] = '\0';
    return s;
}
EOF

    $CC $CFLAGS -I"$SRC/bootstrap" -c "$SRC/bootstrap/sqlite3_stub.c" -o "$SRC/bootstrap/sqlite3_stub.o"
    "$AR" rcs "$STAGE/usr/lib/libsqlite3.a" "$SRC/bootstrap/sqlite3_stub.o"

    install -m644 "$SRC/bootstrap/sqlite3.h" "$STAGE/usr/include/sqlite3.h"

    cat > "$STAGE/usr/lib/pkgconfig/sqlite3.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: sqlite3
Description: Bootstrap sqlite3 compatibility shim
Version: 3.51.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lsqlite3
EOF

    cat > "$STAGE/usr/lib/pkgconfig/sqlite.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: sqlite
Description: Bootstrap sqlite compatibility shim
Version: 3.51.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lsqlite3
EOF
}

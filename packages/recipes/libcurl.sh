#!/bin/sh
# Recipe: libcurl - minimal libcurl compatibility shim for wasm32

NAME="libcurl"
VERSION="0.1.0"
DESCRIPTION="Minimal libcurl compatibility shim"
SOURCE_URL="https://curl.se/download/curl-8.13.0.tar.gz"

build() {
    install -d "$SRC/bootstrap/curl" "$STAGE/usr/include/curl" "$STAGE/usr/lib" "$STAGE/usr/lib/pkgconfig"

    cat > "$SRC/bootstrap/curl/curl.h" << 'EOF'
#ifndef LOT_BOOTSTRAP_CURL_H
#define LOT_BOOTSTRAP_CURL_H

#include <stddef.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LIBCURL_VERSION "8.13.0-stub"
#define LIBCURL_VERSION_NUM 0x080d00

typedef long curl_off_t;

typedef struct CURL CURL;
typedef struct CURLM CURLM;

typedef int CURLcode;
typedef int CURLMcode;
typedef int CURLoption;
typedef int CURLINFO;
typedef int CURLMoption;
typedef int curl_infotype;

enum {
    CURLE_OK = 0,
    CURLE_UNSUPPORTED_PROTOCOL = 1,
    CURLE_FAILED_INIT = 2,
    CURLE_URL_MALFORMAT = 3,
    CURLE_NOT_BUILT_IN = 4,
    CURLE_REMOTE_ACCESS_DENIED = 9,
    CURLE_FILE_COULDNT_READ_FILE = 37,
    CURLE_FUNCTION_NOT_FOUND = 41,
    CURLE_ABORTED_BY_CALLBACK = 42,
    CURLE_BAD_FUNCTION_ARGUMENT = 43,
    CURLE_INTERFACE_FAILED = 45,
    CURLE_TOO_MANY_REDIRECTS = 47,
    CURLE_UNKNOWN_OPTION = 48,
    CURLE_SSL_CACERT_BADFILE = 77,
    CURLE_WRITE_ERROR = 23
};

enum {
    CURLM_OK = 0
};

enum {
    CURLMSG_DONE = 1
};

enum {
    CURLINFO_TEXT = 0,
    CURLINFO_PROTOCOL = 0x200000 + 181,
    CURLINFO_RESPONSE_CODE = 0x200000 + 2,
    CURLINFO_EFFECTIVE_URL = 0x100000 + 1
};

enum {
    CURLPROTO_HTTP = 1 << 0,
    CURLPROTO_HTTPS = 1 << 1
};

enum {
    CURLOPT_VERBOSE = 41,
    CURLOPT_DEBUGFUNCTION = 94,
    CURLOPT_URL = 10002,
    CURLOPT_FOLLOWLOCATION = 52,
    CURLOPT_MAXREDIRS = 68,
    CURLOPT_NOSIGNAL = 99,
    CURLOPT_USERAGENT = 10018,
    CURLOPT_PIPEWAIT = 237,
    CURLOPT_HTTP_VERSION = 84,
    CURLOPT_WRITEFUNCTION = 20011,
    CURLOPT_WRITEDATA = 10001,
    CURLOPT_HEADERFUNCTION = 20079,
    CURLOPT_HEADERDATA = 10029,
    CURLOPT_PROGRESSFUNCTION = 20056,
    CURLOPT_PROGRESSDATA = 10057,
    CURLOPT_NOPROGRESS = 43,
    CURLOPT_HTTPHEADER = 10023,
    CURLOPT_MAX_RECV_SPEED_LARGE = 30146,
    CURLOPT_NOBODY = 44,
    CURLOPT_UPLOAD = 46,
    CURLOPT_READFUNCTION = 20012,
    CURLOPT_READDATA = 10009,
    CURLOPT_INFILESIZE_LARGE = 30115,
    CURLOPT_CAINFO = 10065,
    CURLOPT_SSL_VERIFYPEER = 64,
    CURLOPT_SSL_VERIFYHOST = 81,
    CURLOPT_CONNECTTIMEOUT = 78,
    CURLOPT_LOW_SPEED_LIMIT = 19,
    CURLOPT_LOW_SPEED_TIME = 20,
    CURLOPT_NETRC_FILE = 10118,
    CURLOPT_NETRC = 51,
    CURLOPT_RESUME_FROM_LARGE = 30116
};

enum {
    CURLMOPT_PIPELINING = 3,
    CURLMOPT_MAX_TOTAL_CONNECTIONS = 13
};

enum {
    CURLPIPE_MULTIPLEX = 2
};

enum {
    CURL_WAIT_POLLIN = 0x01
};

enum {
    CURL_NETRC_OPTIONAL = 1
};

enum {
    CURL_HTTP_VERSION_1_1 = 2,
    CURL_HTTP_VERSION_2TLS = 4
};

enum {
    CURL_GLOBAL_ALL = 3
};

struct curl_slist {
    char *data;
    struct curl_slist *next;
};

typedef struct {
    int msg;
    CURL *easy_handle;
    union {
        void *whatever;
        CURLcode result;
    } data;
} CURLMsg;

struct curl_waitfd {
    int fd;
    short events;
    short revents;
};

CURL *curl_easy_init(void);
void curl_easy_reset(CURL *curl);
void curl_easy_cleanup(CURL *curl);
CURLcode curl_easy_setopt(CURL *curl, CURLoption option, ...);
CURLcode curl_easy_getinfo(CURL *curl, CURLINFO info, ...);
const char *curl_easy_strerror(CURLcode errornum);

struct curl_slist *curl_slist_append(struct curl_slist *list, const char *string);
void curl_slist_free_all(struct curl_slist *list);

CURLcode curl_global_init(long flags);

CURLM *curl_multi_init(void);
CURLMcode curl_multi_setopt(CURLM *multi_handle, CURLMoption option, ...);
CURLMcode curl_multi_cleanup(CURLM *multi_handle);
CURLMcode curl_multi_perform(CURLM *multi_handle, int *running_handles);
CURLMsg *curl_multi_info_read(CURLM *multi_handle, int *msgs_in_queue);
CURLMcode curl_multi_remove_handle(CURLM *multi_handle, CURL *curl_handle);
CURLMcode curl_multi_add_handle(CURLM *multi_handle, CURL *curl_handle);
CURLMcode curl_multi_wait(CURLM *multi_handle, struct curl_waitfd extra_fds[], unsigned int extra_nfds, int timeout_ms, int *numfds);
const char *curl_multi_strerror(CURLMcode code);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$SRC/bootstrap/libcurl_stub.c" << 'EOF'
#include <stdlib.h>
#include <string.h>

#include "curl/curl.h"

struct CURL { int dummy; };
struct CURLM { int dummy; };

CURL *curl_easy_init(void)
{
    return (CURL *) calloc(1, sizeof(CURL));
}

void curl_easy_reset(CURL *curl)
{
    (void) curl;
}

void curl_easy_cleanup(CURL *curl)
{
    free(curl);
}

CURLcode curl_easy_setopt(CURL *curl, CURLoption option, ...)
{
    (void) curl;
    (void) option;
    return CURLE_OK;
}

CURLcode curl_easy_getinfo(CURL *curl, CURLINFO info, ...)
{
    (void) curl;
    va_list ap;
    va_start(ap, info);
    if (info == CURLINFO_PROTOCOL) {
        long *p = va_arg(ap, long *);
        if (p) *p = CURLPROTO_HTTP;
    } else if (info == CURLINFO_RESPONSE_CODE) {
        long *p = va_arg(ap, long *);
        if (p) *p = 200;
    } else if (info == CURLINFO_EFFECTIVE_URL) {
        char **p = va_arg(ap, char **);
        if (p) *p = (char *) "";
    } else {
        (void) va_arg(ap, void *);
    }
    va_end(ap);
    return CURLE_OK;
}

const char *curl_easy_strerror(CURLcode errornum)
{
    (void) errornum;
    return "libcurl stub";
}

struct curl_slist *curl_slist_append(struct curl_slist *list, const char *string)
{
    struct curl_slist *node = (struct curl_slist *) calloc(1, sizeof(struct curl_slist));
    if (!node) return list;
    if (string) {
        size_t n = strlen(string);
        node->data = (char *) malloc(n + 1);
        if (node->data) memcpy(node->data, string, n + 1);
    }
    node->next = NULL;
    if (!list) return node;
    struct curl_slist *tail = list;
    while (tail->next) tail = tail->next;
    tail->next = node;
    return list;
}

void curl_slist_free_all(struct curl_slist *list)
{
    while (list) {
        struct curl_slist *next = list->next;
        free(list->data);
        free(list);
        list = next;
    }
}

CURLcode curl_global_init(long flags)
{
    (void) flags;
    return CURLE_OK;
}

CURLM *curl_multi_init(void)
{
    return (CURLM *) calloc(1, sizeof(CURLM));
}

CURLMcode curl_multi_setopt(CURLM *multi_handle, CURLMoption option, ...)
{
    (void) multi_handle;
    (void) option;
    return CURLM_OK;
}

CURLMcode curl_multi_cleanup(CURLM *multi_handle)
{
    free(multi_handle);
    return CURLM_OK;
}

CURLMcode curl_multi_perform(CURLM *multi_handle, int *running_handles)
{
    (void) multi_handle;
    if (running_handles) *running_handles = 0;
    return CURLM_OK;
}

CURLMsg *curl_multi_info_read(CURLM *multi_handle, int *msgs_in_queue)
{
    (void) multi_handle;
    if (msgs_in_queue) *msgs_in_queue = 0;
    return NULL;
}

CURLMcode curl_multi_remove_handle(CURLM *multi_handle, CURL *curl_handle)
{
    (void) multi_handle;
    (void) curl_handle;
    return CURLM_OK;
}

CURLMcode curl_multi_add_handle(CURLM *multi_handle, CURL *curl_handle)
{
    (void) multi_handle;
    (void) curl_handle;
    return CURLM_OK;
}

CURLMcode curl_multi_wait(CURLM *multi_handle, struct curl_waitfd extra_fds[], unsigned int extra_nfds, int timeout_ms, int *numfds)
{
    (void) multi_handle;
    (void) extra_fds;
    (void) extra_nfds;
    (void) timeout_ms;
    if (numfds) *numfds = 0;
    return CURLM_OK;
}

const char *curl_multi_strerror(CURLMcode code)
{
    (void) code;
    return "libcurl-multi stub";
}
EOF

    $CC $CFLAGS -I"$SRC/bootstrap" -c "$SRC/bootstrap/libcurl_stub.c" -o "$SRC/bootstrap/libcurl_stub.o"
    "$AR" rcs "$STAGE/usr/lib/libcurl.a" "$SRC/bootstrap/libcurl_stub.o"

    install -m644 "$SRC/bootstrap/curl/curl.h" "$STAGE/usr/include/curl/curl.h"

    cat > "$STAGE/usr/lib/pkgconfig/libcurl.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: libcurl
Description: Bootstrap libcurl compatibility shim
Version: 8.13.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lcurl
EOF

    cat > "$STAGE/usr/lib/pkgconfig/curl.pc" << 'EOF'
prefix=/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=/usr/include

Name: curl
Description: Bootstrap curl compatibility shim
Version: 8.13.0
Cflags: -I/usr/include
Libs: -L/usr/lib -lcurl
EOF
}

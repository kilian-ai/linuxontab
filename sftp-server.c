/*
 * Minimal SFTP v3 server for LinuxOnTab (WASM target).
 * Reads/writes SSH_MSG_CHANNEL_DATA packets on stdin/stdout.
 * Implements SFTP v3 wire protocol directly (no SSH2 framing needed -
 * the parent dropbear process already handles the SSH channel, we just
 * do the 4-byte-length-prefixed SFTP packets on stdin/stdout).
 *
 * Supported ops: INIT, REALPATH, STAT, LSTAT, FSTAT, OPEN, CLOSE, READ,
 * WRITE, OPENDIR, READDIR, MKDIR, RMDIR, REMOVE, RENAME, SETSTAT, FSETSTAT.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

/* ---- SFTP packet types ---- */
#define SSH_FXP_INIT        1
#define SSH_FXP_VERSION     2
#define SSH_FXP_OPEN        3
#define SSH_FXP_CLOSE       4
#define SSH_FXP_READ        5
#define SSH_FXP_WRITE       6
#define SSH_FXP_LSTAT       7
#define SSH_FXP_FSTAT       8
#define SSH_FXP_SETSTAT     9
#define SSH_FXP_FSETSTAT   10
#define SSH_FXP_OPENDIR    11
#define SSH_FXP_READDIR    12
#define SSH_FXP_REMOVE     13
#define SSH_FXP_MKDIR      14
#define SSH_FXP_RMDIR      15
#define SSH_FXP_REALPATH   16
#define SSH_FXP_STAT       17
#define SSH_FXP_RENAME     18
#define SSH_FXP_READLINK   19
#define SSH_FXP_SYMLINK    20
#define SSH_FXP_STATUS    101
#define SSH_FXP_HANDLE    102
#define SSH_FXP_DATA      103
#define SSH_FXP_NAME      104
#define SSH_FXP_ATTRS     105

/* ---- SFTP status codes ---- */
#define SSH_FX_OK                0
#define SSH_FX_EOF               1
#define SSH_FX_NO_SUCH_FILE      2
#define SSH_FX_PERMISSION_DENIED 3
#define SSH_FX_FAILURE           4
#define SSH_FX_BAD_MESSAGE       5
#define SSH_FX_NO_CONNECTION     6
#define SSH_FX_CONNECTION_LOST   7
#define SSH_FX_OP_UNSUPPORTED    8

/* ---- SFTP open flags ---- */
#define SSH_FXF_READ   0x01
#define SSH_FXF_WRITE  0x02
#define SSH_FXF_APPEND 0x04
#define SSH_FXF_CREAT  0x08
#define SSH_FXF_TRUNC  0x10
#define SSH_FXF_EXCL   0x20

/* ---- SFTP attr flags ---- */
#define SSH_FILEXFER_ATTR_SIZE        0x00000001
#define SSH_FILEXFER_ATTR_UIDGID      0x00000002
#define SSH_FILEXFER_ATTR_PERMISSIONS 0x00000004
#define SSH_FILEXFER_ATTR_ACMODTIME   0x00000008

/* ---- stubs for unused long-double ops pulled in by musl's vfprintf ---- */
typedef __int128 __ti_type;
__ti_type __multi3(__ti_type a, __ti_type b) { __builtin_trap(); }
typedef long double __tf_type;
__tf_type __addtf3(__tf_type a, __tf_type b) { __builtin_trap(); }
__tf_type __subtf3(__tf_type a, __tf_type b) { __builtin_trap(); }
__tf_type __multf3(__tf_type a, __tf_type b) { __builtin_trap(); }
__tf_type __extenddftf2(double a) { __builtin_trap(); }
int __eqtf2(__tf_type a, __tf_type b)    { __builtin_trap(); }
int __netf2(__tf_type a, __tf_type b)    { __builtin_trap(); }
int __unordtf2(__tf_type a, __tf_type b) { __builtin_trap(); }
unsigned __fixunstfsi(__tf_type a) { __builtin_trap(); }
int __fixtfsi(__tf_type a) { __builtin_trap(); }
__tf_type __floatunsitf(unsigned a) { __builtin_trap(); }
__tf_type __floatsitf(int a) { __builtin_trap(); }
double __trunctfdf2(__tf_type a) { __builtin_trap(); }
float __trunctfsf2(__tf_type a) { __builtin_trap(); }

/* ---- max packet/path sizes ---- */
#define MAX_PACKET  (256 * 1024)
#define MAX_HANDLES 64
#define MAX_PATH    4096

/* ---- handle table ---- */
typedef enum { H_FREE = 0, H_FILE, H_DIR } htype_t;

typedef struct {
    htype_t type;
    int     fd;     /* file handles */
    DIR    *dir;    /* dir handles */
    int     direof; /* hit end of dir */
} handle_t;

static handle_t handles[MAX_HANDLES];

static int alloc_handle(void) {
    for (int i = 0; i < MAX_HANDLES; i++)
        if (handles[i].type == H_FREE) return i;
    return -1;
}

/* ---- I/O helpers ---- */
static int read_all(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, p + done, n - done);
        if (r <= 0) return -1;
        done += r;
    }
    return 0;
}

static int write_all(int fd, const void *buf, size_t n) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t done = 0;
    while (done < n) {
        ssize_t r = write(fd, p + done, n - done);
        if (r <= 0) return -1;
        done += r;
    }
    return 0;
}

/* ---- dynamic response buffer ---- */
typedef struct {
    uint8_t *data;
    size_t   cap;
    size_t   len;
} buf_t;

static void buf_init(buf_t *b) { b->data = NULL; b->cap = b->len = 0; }
static void buf_free(buf_t *b) { free(b->data); buf_init(b); }

static void buf_ensure(buf_t *b, size_t extra) {
    size_t need = b->len + extra;
    if (need > b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 256;
        while (nc < need) nc *= 2;
        b->data = realloc(b->data, nc);
        b->cap = nc;
    }
}

static void put_u8(buf_t *b, uint8_t v) {
    buf_ensure(b, 1);
    b->data[b->len++] = v;
}
static void put_u32(buf_t *b, uint32_t v) {
    buf_ensure(b, 4);
    b->data[b->len++] = (v >> 24) & 0xff;
    b->data[b->len++] = (v >> 16) & 0xff;
    b->data[b->len++] = (v >>  8) & 0xff;
    b->data[b->len++] =  v        & 0xff;
}
static void put_u64(buf_t *b, uint64_t v) {
    put_u32(b, (uint32_t)(v >> 32));
    put_u32(b, (uint32_t)(v & 0xffffffff));
}
static void put_str(buf_t *b, const char *s) {
    size_t l = strlen(s);
    put_u32(b, (uint32_t)l);
    buf_ensure(b, l);
    memcpy(b->data + b->len, s, l);
    b->len += l;
}
static void put_bytes(buf_t *b, const void *d, size_t n) {
    put_u32(b, (uint32_t)n);
    buf_ensure(b, n);
    memcpy(b->data + b->len, d, n);
    b->len += n;
}

/* ---- parse helpers ---- */
typedef struct {
    const uint8_t *data;
    size_t len, pos;
} rbuf_t;

static uint32_t get_u32(rbuf_t *r) {
    if (r->pos + 4 > r->len) return 0;
    uint32_t v = ((uint32_t)r->data[r->pos]   << 24) |
                 ((uint32_t)r->data[r->pos+1] << 16) |
                 ((uint32_t)r->data[r->pos+2] <<  8) |
                  (uint32_t)r->data[r->pos+3];
    r->pos += 4;
    return v;
}
static uint64_t get_u64(rbuf_t *r) {
    uint64_t hi = get_u32(r);
    uint64_t lo = get_u32(r);
    return (hi << 32) | lo;
}
static char *get_string(rbuf_t *r, size_t *outlen) {
    if (r->pos + 4 > r->len) return NULL;
    uint32_t l = get_u32(r);
    if (r->pos + l > r->len) return NULL;
    char *s = malloc(l + 1);
    if (!s) return NULL;
    memcpy(s, r->data + r->pos, l);
    s[l] = '\0';
    r->pos += l;
    if (outlen) *outlen = l;
    return s;
}
/* skip attrs: read but ignore */
static void skip_attrs(rbuf_t *r) {
    if (r->pos + 4 > r->len) return;
    uint32_t flags = get_u32(r);
    if (flags & SSH_FILEXFER_ATTR_SIZE)        { if (r->pos + 8 <= r->len) r->pos += 8; }
    if (flags & SSH_FILEXFER_ATTR_UIDGID)      { if (r->pos + 8 <= r->len) r->pos += 8; }
    if (flags & SSH_FILEXFER_ATTR_PERMISSIONS) { if (r->pos + 4 <= r->len) r->pos += 4; }
    if (flags & SSH_FILEXFER_ATTR_ACMODTIME)   { if (r->pos + 8 <= r->len) r->pos += 8; }
}
static uint32_t read_attrs_perms(rbuf_t *r) {
    if (r->pos + 4 > r->len) return 0644;
    uint32_t flags = get_u32(r);
    uint32_t perms = 0644;
    if (flags & SSH_FILEXFER_ATTR_SIZE)        { if (r->pos + 8 <= r->len) r->pos += 8; }
    if (flags & SSH_FILEXFER_ATTR_UIDGID)      { if (r->pos + 8 <= r->len) r->pos += 8; }
    if (flags & SSH_FILEXFER_ATTR_PERMISSIONS) {
        if (r->pos + 4 <= r->len) { perms = get_u32(r); } }
    if (flags & SSH_FILEXFER_ATTR_ACMODTIME)   { if (r->pos + 8 <= r->len) r->pos += 8; }
    return perms;
}

/* ---- encode stat attrs ---- */
static void put_attrs(buf_t *b, const struct stat *st) {
    uint32_t flags = SSH_FILEXFER_ATTR_SIZE |
                     SSH_FILEXFER_ATTR_UIDGID |
                     SSH_FILEXFER_ATTR_PERMISSIONS |
                     SSH_FILEXFER_ATTR_ACMODTIME;
    put_u32(b, flags);
    put_u64(b, (uint64_t)st->st_size);
    put_u32(b, (uint32_t)st->st_uid);
    put_u32(b, (uint32_t)st->st_gid);
    put_u32(b, (uint32_t)st->st_mode);
    put_u32(b, (uint32_t)st->st_atime);
    put_u32(b, (uint32_t)st->st_mtime);
}

static void put_empty_attrs(buf_t *b) {
    put_u32(b, 0);
}

/* ---- errno -> SSH_FX code ---- */
static uint32_t errno_to_fx(void) {
    switch (errno) {
    case ENOENT:  return SSH_FX_NO_SUCH_FILE;
    case EACCES:
    case EPERM:   return SSH_FX_PERMISSION_DENIED;
    case EEXIST:  return SSH_FX_FAILURE;
    default:      return SSH_FX_FAILURE;
    }
}

/* ---- send a complete SFTP response packet ---- */
static void send_packet(buf_t *b) {
    uint32_t plen = (uint32_t)b->len;
    uint8_t hdr[4];
    hdr[0] = (plen >> 24) & 0xff;
    hdr[1] = (plen >> 16) & 0xff;
    hdr[2] = (plen >>  8) & 0xff;
    hdr[3] =  plen        & 0xff;
    write_all(STDOUT_FILENO, hdr, 4);
    write_all(STDOUT_FILENO, b->data, b->len);
    buf_free(b);
}

static void send_status(uint32_t id, uint32_t code, const char *msg) {
    buf_t b; buf_init(&b);
    put_u8(&b, SSH_FXP_STATUS);
    put_u32(&b, id);
    put_u32(&b, code);
    put_str(&b, msg ? msg : "");
    put_str(&b, "en");
    send_packet(&b);
}

static void send_handle(uint32_t id, int h) {
    buf_t b; buf_init(&b);
    put_u8(&b, SSH_FXP_HANDLE);
    put_u32(&b, id);
    put_bytes(&b, &h, sizeof(int));
    send_packet(&b);
}

/* ---- decode handle from string ---- */
static int decode_handle(const char *s, size_t l) {
    if (l != sizeof(int)) return -1;
    int h; memcpy(&h, s, sizeof(int));
    if (h < 0 || h >= MAX_HANDLES) return -1;
    return h;
}

/* ---- longname for READDIR ---- */
static void make_longname(char *out, size_t outsz, const char *name, const struct stat *st) {
    char tstr[64];
    struct tm tm;
    localtime_r(&st->st_mtime, &tm);
    strftime(tstr, sizeof(tstr), "%b %e %H:%M", &tm);

    char type = '-';
    if (S_ISDIR(st->st_mode))  type = 'd';
    else if (S_ISLNK(st->st_mode)) type = 'l';

    snprintf(out, outsz, "%c%c%c%c%c%c%c%c%c%c %3d %-8d %-8d %8lld %s %s",
             type,
             (st->st_mode & S_IRUSR) ? 'r' : '-',
             (st->st_mode & S_IWUSR) ? 'w' : '-',
             (st->st_mode & S_IXUSR) ? 'x' : '-',
             (st->st_mode & S_IRGRP) ? 'r' : '-',
             (st->st_mode & S_IWGRP) ? 'w' : '-',
             (st->st_mode & S_IXGRP) ? 'x' : '-',
             (st->st_mode & S_IROTH) ? 'r' : '-',
             (st->st_mode & S_IWOTH) ? 'w' : '-',
             (st->st_mode & S_IXOTH) ? 'x' : '-',
             (int)st->st_nlink,
             (int)st->st_uid,
             (int)st->st_gid,
             (long long)st->st_size,
             tstr,
             name);
}

/* ---- main dispatch ---- */
static void handle_packet(const uint8_t *pkt, size_t plen) {
    if (plen < 1) return;
    rbuf_t r = { pkt, plen, 0 };
    uint8_t type = pkt[0]; r.pos = 1;

    if (type == SSH_FXP_INIT) {
        uint32_t client_ver = get_u32(&r);
        (void)client_ver;
        buf_t b; buf_init(&b);
        put_u8(&b, SSH_FXP_VERSION);
        put_u32(&b, 3);  /* SFTP version 3 */
        send_packet(&b);
        return;
    }

    uint32_t id = get_u32(&r);

    switch (type) {

    case SSH_FXP_REALPATH: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad realpath"); return; }
        char resolved[MAX_PATH];
        if (!realpath(path, resolved)) {
            /* fallback: if path doesn't exist, just clean it up */
            snprintf(resolved, sizeof(resolved), "%s", path);
        }
        free(path);
        buf_t b; buf_init(&b);
        put_u8(&b, SSH_FXP_NAME);
        put_u32(&b, id);
        put_u32(&b, 1);
        put_str(&b, resolved);
        put_str(&b, resolved);
        put_empty_attrs(&b);
        send_packet(&b);
        break;
    }

    case SSH_FXP_STAT:
    case SSH_FXP_LSTAT: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad path"); return; }
        struct stat st;
        int rc = (type == SSH_FXP_STAT) ? stat(path, &st) : lstat(path, &st);
        free(path);
        if (rc < 0) {
            send_status(id, errno_to_fx(), strerror(errno));
        } else {
            buf_t b; buf_init(&b);
            put_u8(&b, SSH_FXP_ATTRS);
            put_u32(&b, id);
            put_attrs(&b, &st);
            send_packet(&b);
        }
        break;
    }

    case SSH_FXP_FSTAT: {
        char *hs; size_t hl;
        hs = get_string(&r, &hl);
        if (!hs) { send_status(id, SSH_FX_BAD_MESSAGE, "bad handle"); return; }
        int h = decode_handle(hs, hl); free(hs);
        if (h < 0 || handles[h].type == H_FREE) {
            send_status(id, SSH_FX_FAILURE, "invalid handle"); return;
        }
        struct stat st;
        int rc = (handles[h].type == H_FILE) ?
                 fstat(handles[h].fd, &st) :
                 fstat(dirfd(handles[h].dir), &st);
        if (rc < 0) {
            send_status(id, errno_to_fx(), strerror(errno));
        } else {
            buf_t b; buf_init(&b);
            put_u8(&b, SSH_FXP_ATTRS);
            put_u32(&b, id);
            put_attrs(&b, &st);
            send_packet(&b);
        }
        break;
    }

    case SSH_FXP_OPEN: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad path"); return; }
        uint32_t pflags = get_u32(&r);
        skip_attrs(&r);

        int flags = 0;
        if ((pflags & SSH_FXF_READ) && (pflags & SSH_FXF_WRITE)) flags = O_RDWR;
        else if (pflags & SSH_FXF_WRITE) flags = O_WRONLY;
        else flags = O_RDONLY;
        if (pflags & SSH_FXF_CREAT) flags |= O_CREAT;
        if (pflags & SSH_FXF_TRUNC) flags |= O_TRUNC;
        if (pflags & SSH_FXF_EXCL)  flags |= O_EXCL;
        if (pflags & SSH_FXF_APPEND) flags |= O_APPEND;

        int fd = open(path, flags, 0644);
        free(path);
        if (fd < 0) {
            send_status(id, errno_to_fx(), strerror(errno));
            return;
        }
        int h = alloc_handle();
        if (h < 0) { close(fd); send_status(id, SSH_FX_FAILURE, "out of handles"); return; }
        handles[h].type = H_FILE;
        handles[h].fd   = fd;
        send_handle(id, h);
        break;
    }

    case SSH_FXP_CLOSE: {
        char *hs; size_t hl;
        hs = get_string(&r, &hl);
        if (!hs) { send_status(id, SSH_FX_BAD_MESSAGE, "bad handle"); return; }
        int h = decode_handle(hs, hl); free(hs);
        if (h < 0 || handles[h].type == H_FREE) {
            send_status(id, SSH_FX_FAILURE, "invalid handle"); return;
        }
        if (handles[h].type == H_FILE)  close(handles[h].fd);
        if (handles[h].type == H_DIR)   closedir(handles[h].dir);
        handles[h].type = H_FREE;
        send_status(id, SSH_FX_OK, "");
        break;
    }

    case SSH_FXP_READ: {
        char *hs; size_t hl;
        hs = get_string(&r, &hl);
        if (!hs) { send_status(id, SSH_FX_BAD_MESSAGE, "bad handle"); return; }
        int h = decode_handle(hs, hl); free(hs);
        if (h < 0 || handles[h].type != H_FILE) {
            send_status(id, SSH_FX_FAILURE, "invalid handle"); return;
        }
        uint64_t offset = get_u64(&r);
        uint32_t len    = get_u32(&r);
        if (len > 32768) len = 32768;

        uint8_t *data = malloc(len);
        if (!data) { send_status(id, SSH_FX_FAILURE, "oom"); return; }

        ssize_t n = pread(handles[h].fd, data, len, (off_t)offset);
        if (n < 0) {
            free(data);
            send_status(id, errno_to_fx(), strerror(errno));
        } else if (n == 0) {
            free(data);
            send_status(id, SSH_FX_EOF, "EOF");
        } else {
            buf_t b; buf_init(&b);
            put_u8(&b, SSH_FXP_DATA);
            put_u32(&b, id);
            put_bytes(&b, data, n);
            free(data);
            send_packet(&b);
        }
        break;
    }

    case SSH_FXP_WRITE: {
        char *hs; size_t hl;
        hs = get_string(&r, &hl);
        if (!hs) { send_status(id, SSH_FX_BAD_MESSAGE, "bad handle"); return; }
        int h = decode_handle(hs, hl); free(hs);
        if (h < 0 || handles[h].type != H_FILE) {
            send_status(id, SSH_FX_FAILURE, "invalid handle"); return;
        }
        uint64_t offset = get_u64(&r);
        if (r.pos + 4 > r.len) { send_status(id, SSH_FX_BAD_MESSAGE, "short"); return; }
        uint32_t dlen = get_u32(&r);
        if (r.pos + dlen > r.len) { send_status(id, SSH_FX_BAD_MESSAGE, "short data"); return; }
        const uint8_t *wdata = r.data + r.pos;

        ssize_t n = pwrite(handles[h].fd, wdata, dlen, (off_t)offset);
        if (n < 0) send_status(id, errno_to_fx(), strerror(errno));
        else       send_status(id, SSH_FX_OK, "");
        break;
    }

    case SSH_FXP_OPENDIR: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad path"); return; }
        DIR *dir = opendir(path);
        free(path);
        if (!dir) {
            send_status(id, errno_to_fx(), strerror(errno));
            return;
        }
        int h = alloc_handle();
        if (h < 0) { closedir(dir); send_status(id, SSH_FX_FAILURE, "out of handles"); return; }
        handles[h].type   = H_DIR;
        handles[h].dir    = dir;
        handles[h].direof = 0;
        send_handle(id, h);
        break;
    }

    case SSH_FXP_READDIR: {
        char *hs; size_t hl;
        hs = get_string(&r, &hl);
        if (!hs) { send_status(id, SSH_FX_BAD_MESSAGE, "bad handle"); return; }
        int h = decode_handle(hs, hl); free(hs);
        if (h < 0 || handles[h].type != H_DIR) {
            send_status(id, SSH_FX_FAILURE, "invalid handle"); return;
        }
        if (handles[h].direof) {
            send_status(id, SSH_FX_EOF, "EOF");
            return;
        }
        /* Return up to 64 entries per call */
        buf_t b; buf_init(&b);
        put_u8(&b, SSH_FXP_NAME);
        put_u32(&b, id);
        /* placeholder for count */
        size_t count_pos = b.len;
        put_u32(&b, 0);
        uint32_t count = 0;

        struct dirent *de;
        int dirfd_val = dirfd(handles[h].dir);
        while (count < 64 && (de = readdir(handles[h].dir)) != NULL) {
            struct stat st;
            char longname[512];
            if (fstatat(dirfd_val, de->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0) {
                memset(&st, 0, sizeof(st));
                st.st_mode = 0100644;
            }
            make_longname(longname, sizeof(longname), de->d_name, &st);
            put_str(&b, de->d_name);
            put_str(&b, longname);
            put_attrs(&b, &st);
            count++;
        }
        if (count == 0) {
            buf_free(&b);
            handles[h].direof = 1;
            send_status(id, SSH_FX_EOF, "EOF");
            return;
        }
        /* patch count */
        b.data[count_pos+0] = (count >> 24) & 0xff;
        b.data[count_pos+1] = (count >> 16) & 0xff;
        b.data[count_pos+2] = (count >>  8) & 0xff;
        b.data[count_pos+3] =  count        & 0xff;
        send_packet(&b);
        break;
    }

    case SSH_FXP_MKDIR: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad path"); return; }
        uint32_t perms = read_attrs_perms(&r);
        int rc = mkdir(path, perms & 07777);
        free(path);
        if (rc < 0) send_status(id, errno_to_fx(), strerror(errno));
        else        send_status(id, SSH_FX_OK, "");
        break;
    }

    case SSH_FXP_RMDIR: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad path"); return; }
        int rc = rmdir(path);
        free(path);
        if (rc < 0) send_status(id, errno_to_fx(), strerror(errno));
        else        send_status(id, SSH_FX_OK, "");
        break;
    }

    case SSH_FXP_REMOVE: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad path"); return; }
        int rc = unlink(path);
        free(path);
        if (rc < 0) send_status(id, errno_to_fx(), strerror(errno));
        else        send_status(id, SSH_FX_OK, "");
        break;
    }

    case SSH_FXP_RENAME: {
        char *oldp = get_string(&r, NULL);
        char *newp = get_string(&r, NULL);
        if (!oldp || !newp) {
            free(oldp); free(newp);
            send_status(id, SSH_FX_BAD_MESSAGE, "bad paths"); return;
        }
        int rc = rename(oldp, newp);
        free(oldp); free(newp);
        if (rc < 0) send_status(id, errno_to_fx(), strerror(errno));
        else        send_status(id, SSH_FX_OK, "");
        break;
    }

    case SSH_FXP_SETSTAT: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad path"); return; }
        /* parse attrs: apply permissions if present */
        if (r.pos + 4 <= r.len) {
            uint32_t flags = get_u32(&r);
            if (flags & SSH_FILEXFER_ATTR_SIZE) {
                if (r.pos + 8 <= r.len) {
                    uint64_t sz = get_u64(&r);
                    truncate(path, (off_t)sz);
                }
            }
            if (flags & SSH_FILEXFER_ATTR_UIDGID) r.pos += 8;
            if (flags & SSH_FILEXFER_ATTR_PERMISSIONS) {
                if (r.pos + 4 <= r.len) {
                    uint32_t m = get_u32(&r);
                    chmod(path, m & 07777);
                }
            }
        }
        free(path);
        send_status(id, SSH_FX_OK, "");
        break;
    }

    case SSH_FXP_FSETSTAT: {
        char *hs; size_t hl;
        hs = get_string(&r, &hl);
        if (!hs) { send_status(id, SSH_FX_BAD_MESSAGE, "bad handle"); return; }
        int h = decode_handle(hs, hl); free(hs);
        if (h < 0 || handles[h].type != H_FILE) {
            send_status(id, SSH_FX_FAILURE, "invalid handle"); return;
        }
        if (r.pos + 4 <= r.len) {
            uint32_t flags = get_u32(&r);
            if (flags & SSH_FILEXFER_ATTR_SIZE) {
                if (r.pos + 8 <= r.len) {
                    uint64_t sz = get_u64(&r);
                    ftruncate(handles[h].fd, (off_t)sz);
                }
            }
            if (flags & SSH_FILEXFER_ATTR_UIDGID) r.pos += 8;
            if (flags & SSH_FILEXFER_ATTR_PERMISSIONS) {
                if (r.pos + 4 <= r.len) {
                    uint32_t m = get_u32(&r);
                    fchmod(handles[h].fd, m & 07777);
                }
            }
        }
        send_status(id, SSH_FX_OK, "");
        break;
    }

    case SSH_FXP_READLINK: {
        char *path = get_string(&r, NULL);
        if (!path) { send_status(id, SSH_FX_BAD_MESSAGE, "bad path"); return; }
        char target[MAX_PATH];
        ssize_t n = readlink(path, target, sizeof(target) - 1);
        free(path);
        if (n < 0) {
            send_status(id, errno_to_fx(), strerror(errno));
        } else {
            target[n] = '\0';
            buf_t b; buf_init(&b);
            put_u8(&b, SSH_FXP_NAME);
            put_u32(&b, id);
            put_u32(&b, 1);
            put_str(&b, target);
            put_str(&b, target);
            put_empty_attrs(&b);
            send_packet(&b);
        }
        break;
    }

    case SSH_FXP_SYMLINK: {
        char *tgt  = get_string(&r, NULL);
        char *link = get_string(&r, NULL);
        if (!tgt || !link) {
            free(tgt); free(link);
            send_status(id, SSH_FX_BAD_MESSAGE, "bad paths"); return;
        }
        int rc = symlink(tgt, link);
        free(tgt); free(link);
        if (rc < 0) send_status(id, errno_to_fx(), strerror(errno));
        else        send_status(id, SSH_FX_OK, "");
        break;
    }

    default:
        send_status(id, SSH_FX_OP_UNSUPPORTED, "unsupported");
        break;
    }
}

int main(void) {
    uint8_t lenbuf[4];
    uint8_t *pkt = NULL;
    size_t pkt_cap = 0;

    for (;;) {
        if (read_all(STDIN_FILENO, lenbuf, 4) < 0) break;
        uint32_t plen = ((uint32_t)lenbuf[0] << 24) |
                        ((uint32_t)lenbuf[1] << 16) |
                        ((uint32_t)lenbuf[2] <<  8) |
                         (uint32_t)lenbuf[3];
        if (plen == 0 || plen > (uint32_t)MAX_PACKET) break;
        if (plen > pkt_cap) {
            free(pkt);
            pkt = malloc(plen);
            if (!pkt) break;
            pkt_cap = plen;
        }
        if (read_all(STDIN_FILENO, pkt, plen) < 0) break;
        handle_packet(pkt, plen);
    }
    free(pkt);
    return 0;
}

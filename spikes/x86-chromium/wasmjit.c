/*
 * wasmjit.c — translate hot x86-64 basic blocks to WebAssembly (LinuxOnTab,
 * kilian-ai/linuxontab#14). Built into Blink with -DLOT_WASMJIT.
 *
 * Blink on wasm32 is a pure interpreter: its JIT emits native x86/arm64 code,
 * which a wasm module can't run. This is a call-threaded backend instead:
 *
 * *   - The interpreter counts how often each block START (the pc after a
 *     branch, a syscall or another block) is reached. At WJ_HOT it records
 *     the block while interpreting it: one entry per instruction, holding
 *     the decoded operands (rde, disp, uimm0), the op handler and its length.
 *   - A block ends after a branching op, before a syscall-class op, at the
 *     4 KiB page boundary, or at WJ_MAXOPS. It becomes one wasm function of
 *     the op signature (i32 m, i64 rde, i64 disp, i64 uimm0) that, per
 *     instruction, does what JitlessDispatch does without decoding:
 *         m->ip = pc_after; m->oplen = len; op(m, rde, disp, uimm0);
 *         if (m->stashaddr) CommitStash(m);
 *         if (m->ip != pc_after) { m->oplen = 0; return; }   // left the line
 *     The handlers are called through Blink's own function table
 *     (call_indirect with the handler's function-pointer value), so a
 *     translated block runs the very same op code as the interpreter. The
 *     ip guard after every op makes anything that does not fall through —
 *     a taken branch, a REP op restarting itself, a signal — return to the
 *     interpreter, which carries on from m->ip.
 *   - The module goes to the runtime with syscall(NR_LOT_WASM_LOAD), which
 *     compiles it and appends the function to this thread's function table
 *     (shell/linux-dist-7.1/src/kernel/worker.ts). The returned slot IS the
 *     C function pointer.
 *
 * What it does not do (yet): inline the ops themselves, chain blocks, batch
 * several blocks into one module, compile off the hot path.
 *
 * State is per thread (_Thread_local): every host thread is its own wasm
 * instance with its own function table, so a slot is only valid on the
 * thread that loaded it. A vfork child gets fresh TLS; a fork child copies
 * ours and must call WasmJitAfterFork().
 *
 * Only pages that are executable and NOT writable are translated, so code
 * can't change under a translation without an munmap or mprotect, and those
 * call WasmJitPageChanged(), which bumps that page's generation. Each
 * translation remembers its page record (never freed, so the pointer stays
 * valid) and the generation it was made at; a stale one is dropped and the
 * block counts up again. JITs that flip code pages RW<->RX (V8's Sparkplug)
 * only lose the blocks on the pages they touch.
 *
 * A block whose last op jumps back to its own start (a tight loop) loops
 * inside the wasm function while m->attention is clear, so signals still
 * get through between iterations.
 *
 * BLINK_WASMJIT=0 in the environment turns it off; BLINK_WASMJIT_STATS=1
 * prints counters at exit (SysExitGroup calls WasmJitAtExit).
 */
#ifdef LOT_WASMJIT
#include <errno.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

#include "blink/machine.h"
#include "blink/rde.h"
#include "blink/x86.h"

#define NR_LOT_WASM_LOAD 10001
#define WJ_HOT    1024        /* block starts before translating (BLINK_WASMJIT_HOT): a
                               * module costs ~30-40 us to compile, so only
                               * blocks that run often enough pay that back */
#define WJ_MAXOPS 192         /* instructions per block */
#define WJ_MAXFNS 200000      /* translated blocks per thread (table slots) */

struct WjOp {
  u64 rde;
  i64 disp;
  u64 uimm0;
  u32 fn;
  u8 len;
};

struct WjPage {
  u64 page;
  _Atomic(u32) gen;
};

struct WjEntry {
  u64 pc;
  u32 slot;     /* 0: not translated */
  u32 gen;      /* page generation it was made at */
  struct WjPage *pg;
  u32 count;
  u32 state;    /* 0 counting, 1 translated, 2 never */
};

struct Wj {
  struct WjEntry *tab;
  u32 cap, used;
  bool atstart;
  bool rec;           /* recording a block */
  u64 start, next;    /* recording: block pc, expected next pc */
  struct WjPage *recpg;
  u32 recgen;
  int nops;
  struct WjOp ops[WJ_MAXOPS];
  u8 *code;
  size_t codecap;
  u32 nfns;
};

static _Thread_local struct Wj *g_wj;
static int g_wj_mode = -1;                 /* -1 unknown, 0 off, 1 on */
static u32 g_wj_hot = WJ_HOT;

/* page records of translated code (global, all threads): an open-addressed
 * index of pointers into chunks that are never freed or moved */
static _Atomic(int) g_wj_lock;
static struct WjPage **g_wj_pidx;
static u32 g_wj_pcap, g_wj_pused;
static struct WjPage *g_wj_chunk;
static u32 g_wj_chunkleft;
static _Atomic(u32) g_wj_haspages;

/* stats (approximate, unlocked) */
static long s_blocks, s_failed, s_calls, s_flushes, s_opsum, s_interp;
static bool g_wj_stats;

static void WjLock(void) {
  int z = 0;
  while (!atomic_compare_exchange_weak(&g_wj_lock, &z, 1)) z = 0;
}
static void WjUnlock(void) { atomic_store(&g_wj_lock, 0); }

void WasmJitAtExit(void) {
  if (!g_wj_stats) return;
  fprintf(stderr,
          "[wasmjit] blocks=%ld (avg %.1f ops) failed=%ld block-calls=%ld "
          "interpreted=%ld flushes=%ld\n",
          s_blocks, s_blocks ? (double)s_opsum / s_blocks : 0.0, s_failed,
          s_calls, s_interp, s_flushes);
}

static bool WjEnabled(void) {
  if (g_wj_mode < 0) {
    const char *e = getenv("BLINK_WASMJIT");
    g_wj_mode = !(e && *e == '0');
    const char *st = getenv("BLINK_WASMJIT_STATS");
    g_wj_stats = g_wj_mode && st && *st == '1';
    const char *h = getenv("BLINK_WASMJIT_HOT");
    if (h && atoi(h) > 0) g_wj_hot = atoi(h);
  }
  return g_wj_mode > 0;
}

static struct Wj *WjGet(void) {
  struct Wj *w = g_wj;
  if (!w) {
    if (!(w = calloc(1, sizeof *w))) return 0;
    w->cap = 4096;
    if (!(w->tab = calloc(w->cap, sizeof *w->tab))) { free(w); return 0; }
    w->atstart = true;
    g_wj = w;
  }
  return w;
}

static u32 WjHash(u64 pc) { return (u32)((pc * 0x9E3779B97F4A7C15ull) >> 32); }

static struct WjEntry *WjFind(struct Wj *w, u64 pc) {
  u32 mask = w->cap - 1;
  for (u32 i = WjHash(pc) & mask;; i = (i + 1) & mask) {
    struct WjEntry *e = &w->tab[i];
    if (e->pc == pc && (e->count || e->state)) return e;
    if (!e->count && !e->state) {
      if ((w->used + 1) * 4 > w->cap * 3) {     /* grow at 75 % */
        struct WjEntry *old = w->tab;
        u32 oc = w->cap;
        struct WjEntry *nt = calloc(oc * 2, sizeof *nt);
        if (!nt) return 0;
        w->tab = nt;
        w->cap = oc * 2;
        w->used = 0;
        for (u32 j = 0; j < oc; j++) {
          if (!old[j].count && !old[j].state) continue;
          struct WjEntry *d = WjFind(w, old[j].pc);
          *d = old[j];
        }
        free(old);
        return WjFind(w, pc);
      }
      e->pc = pc;
      w->used++;
      return e;
    }
  }
}

static bool WjTranslatable(struct Machine *m, u64 pc) {
  if (m->mode.omode != XED_MODE_LONG || m->cs.base) return false;
  u64 pte = FindPageTableEntry(m, pc & -4096);
  return (pte & PAGE_V) && !(pte & PAGE_XD) && !(pte & PAGE_RW);
}

static u32 WjPHash(u64 page) { return (u32)((page >> 12) * 0x9E3779B1u); }

/* find (or with add, create) the record for a page; caller holds the lock */
static struct WjPage *WjPageLocked(u64 page, bool add) {
  if (g_wj_pcap) {
    u32 mask = g_wj_pcap - 1;
    for (u32 i = WjPHash(page) & mask; g_wj_pidx[i]; i = (i + 1) & mask)
      if (g_wj_pidx[i]->page == page) return g_wj_pidx[i];
  }
  if (!add) return 0;
  if ((g_wj_pused + 1) * 2 > g_wj_pcap) {
    u32 nc = g_wj_pcap ? g_wj_pcap * 2 : 1024;
    struct WjPage **ni = calloc(nc, sizeof *ni);
    if (!ni) return 0;
    for (u32 j = 0; j < g_wj_pcap; j++) {
      if (!g_wj_pidx[j]) continue;
      u32 k = WjPHash(g_wj_pidx[j]->page) & (nc - 1);
      while (ni[k]) k = (k + 1) & (nc - 1);
      ni[k] = g_wj_pidx[j];
    }
    free(g_wj_pidx);
    g_wj_pidx = ni;
    g_wj_pcap = nc;
  }
  if (!g_wj_chunkleft) {
    if (!(g_wj_chunk = calloc(1024, sizeof *g_wj_chunk))) return 0;
    g_wj_chunkleft = 1024;
  }
  struct WjPage *p = g_wj_chunk++;
  g_wj_chunkleft--;
  p->page = page;
  u32 k = WjPHash(page) & (g_wj_pcap - 1);
  while (g_wj_pidx[k]) k = (k + 1) & (g_wj_pcap - 1);
  g_wj_pidx[k] = p;
  g_wj_pused++;
  atomic_store(&g_wj_haspages, 1);
  return p;
}

void WasmJitPageChanged(i64 virt) {
  if (!atomic_load_explicit(&g_wj_haspages, memory_order_relaxed)) return;
  WjLock();
  struct WjPage *p = WjPageLocked((u64)virt & -4096, false);
  if (p) {
    atomic_fetch_add_explicit(&p->gen, 1, memory_order_release);
    s_flushes++;
  }
  WjUnlock();
}

void WasmJitAfterFork(void) {
  /* the child is a fresh wasm instance: our slots don't exist in it */
  g_wj = 0;
  atomic_store(&g_wj_lock, 0);
}

/* ── wasm emitter ─────────────────────────────────────────────────────────── */
static bool Put(struct Wj *w, size_t *n, const void *p, size_t k) {
  if (*n + k > w->codecap) {
    size_t nc = w->codecap ? w->codecap * 2 : 65536;
    while (nc < *n + k) nc *= 2;
    u8 *nb = realloc(w->code, nc);
    if (!nb) return false;
    w->code = nb;
    w->codecap = nc;
  }
  memcpy(w->code + *n, p, k);
  *n += k;
  return true;
}
static void B(struct Wj *w, size_t *n, u8 b) { Put(w, n, &b, 1); }
static void U(struct Wj *w, size_t *n, u64 v) {       /* unsigned LEB128 */
  do { u8 b = v & 0x7f; v >>= 7; if (v) b |= 0x80; B(w, n, b); } while (v);
}
static void S(struct Wj *w, size_t *n, i64 v) {       /* signed LEB128 */
  for (;;) {
    u8 b = v & 0x7f;
    v >>= 7;
    if ((v == 0 && !(b & 0x40)) || (v == -1 && (b & 0x40))) { B(w, n, b); return; }
    B(w, n, b | 0x80);
  }
}

/* body opcodes */
enum { LGET = 0x20, I32C = 0x41, I64C = 0x42, I64LD = 0x29, I64ST = 0x37,
       I32ST8 = 0x3a, I64NE = 0x52, I64EQZ = 0x50, IF = 0x04, END = 0x0b,
       RET = 0x0f, CALLI = 0x11, EQZ32 = 0x45, LOOP = 0x03, I64EQ = 0x51,
       I32AND = 0x71, BRIF = 0x0d, I32LD8U = 0x2d };

static void Mem(struct Wj *w, size_t *n, u8 op, u32 align, u32 off) {
  B(w, n, op); U(w, n, align); U(w, n, off);
}

static void EmitBody(struct Wj *w, size_t *n) {
  const u32 OIP = offsetof(struct Machine, ip);
  const u32 OLEN = offsetof(struct Machine, oplen);
  const u32 OSTASH = offsetof(struct Machine, stashaddr);
  const u32 COMMIT = (u32)(uintptr_t)CommitStash;
  const u32 OATT = offsetof(struct Machine, attention);
  u64 pc = w->start;
  B(w, n, 0);                                   /* no locals */
  B(w, n, LOOP); B(w, n, 0x40);
  for (int i = 0; i < w->nops; i++) {
    struct WjOp *o = &w->ops[i];
    if (i == 0) pc = w->start;
    pc += o->len;
    /* m->ip = pc; m->oplen = len */
    B(w, n, LGET); U(w, n, 0); B(w, n, I64C); S(w, n, (i64)pc); Mem(w, n, I64ST, 3, OIP);
    B(w, n, LGET); U(w, n, 0); B(w, n, I32C); S(w, n, o->len); Mem(w, n, I32ST8, 0, OLEN);
    /* op(m, rde, disp, uimm0) */
    B(w, n, LGET); U(w, n, 0);
    B(w, n, I64C); S(w, n, (i64)o->rde);
    B(w, n, I64C); S(w, n, o->disp);
    B(w, n, I64C); S(w, n, (i64)o->uimm0);
    B(w, n, I32C); S(w, n, (i32)o->fn);
    B(w, n, CALLI); U(w, n, 0); U(w, n, 0);
    /* if (m->stashaddr) CommitStash(m) */
    B(w, n, LGET); U(w, n, 0); Mem(w, n, I64LD, 3, OSTASH);
    B(w, n, I64EQZ); B(w, n, EQZ32);
    B(w, n, IF); B(w, n, 0x40);
    B(w, n, LGET); U(w, n, 0); B(w, n, I32C); S(w, n, (i32)COMMIT);
    B(w, n, CALLI); U(w, n, 1); U(w, n, 0);
    B(w, n, END);
    if (i + 1 < w->nops) {     /* if (m->ip != pc) { m->oplen = 0; return; } */
      B(w, n, LGET); U(w, n, 0); Mem(w, n, I64LD, 3, OIP);
      B(w, n, I64C); S(w, n, (i64)pc); B(w, n, I64NE);
      B(w, n, IF); B(w, n, 0x40);
      B(w, n, LGET); U(w, n, 0); B(w, n, I32C); S(w, n, 0); Mem(w, n, I32ST8, 0, OLEN);
      B(w, n, RET);
      B(w, n, END);
    }
  }
  /* back to our own start (a loop) and nothing pending: go round again */
  B(w, n, LGET); U(w, n, 0); Mem(w, n, I64LD, 3, OIP);
  B(w, n, I64C); S(w, n, (i64)w->start); B(w, n, I64EQ);
  B(w, n, LGET); U(w, n, 0); Mem(w, n, I32LD8U, 0, OATT); B(w, n, EQZ32);
  B(w, n, I32AND);
  B(w, n, BRIF); U(w, n, 0);
  B(w, n, END);                                 /* loop */
  B(w, n, LGET); U(w, n, 0); B(w, n, I32C); S(w, n, 0); Mem(w, n, I32ST8, 0, OLEN);
  B(w, n, END);
}

/* Assemble the module into w->code; returns its size (0 on failure). */
static size_t EmitModule(struct Wj *w) {
  static const u8 head[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    /* types: 0 = (i32, i64, i64, i64) -> (), 1 = (i32) -> () */
    0x01, 0x0c, 0x02, 0x60, 0x04, 0x7f, 0x7e, 0x7e, 0x7e, 0x00, 0x60, 0x01, 0x7f, 0x00,
    /* imports: env.memory (shared, 0..65536), env.__indirect_function_table */
    0x02, 0x34, 0x02,
    0x03, 'e', 'n', 'v', 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x03, 0x00, 0x80, 0x80, 0x04,
    0x03, 'e', 'n', 'v', 0x19, '_', '_', 'i', 'n', 'd', 'i', 'r', 'e', 'c', 't', '_',
    'f', 'u', 'n', 'c', 't', 'i', 'o', 'n', '_', 't', 'a', 'b', 'l', 'e', 0x01, 0x70, 0x00, 0x00,
    /* one function of type 0, exported as "b" */
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 'b', 0x00, 0x00,
  };
  size_t n = 0, bn;
  if (!Put(w, &n, head, sizeof head)) return 0;
  /* the body goes after a scratch gap so its size is known up front */
  size_t at = n + 16;
  n = at;
  EmitBody(w, &n);
  if (n > w->codecap) return 0;
  bn = n - at;
  /* code section: id, size, count=1, body size, body */
  u8 hdr[16];
  size_t h = 0;
  struct Wj tmp = { .code = hdr, .codecap = sizeof hdr };
  size_t lb = 0;
  { u8 t[8]; size_t k = 0; struct Wj t2 = { .code = t, .codecap = sizeof t }; U(&t2, &k, bn); lb = k; }
  B(&tmp, &h, 0x0a);
  U(&tmp, &h, 1 + lb + bn);
  B(&tmp, &h, 1);
  U(&tmp, &h, bn);
  memmove(w->code + sizeof head + h, w->code + at, bn);
  memcpy(w->code + sizeof head, hdr, h);
  return sizeof head + h + bn;
}

static void WjFinish(struct Machine *m, struct Wj *w) {
  w->rec = false;
  w->atstart = true;
  struct WjEntry *e = WjFind(w, w->start);
  if (!e) return;
  if (!w->nops || w->nfns >= WJ_MAXFNS) { e->state = 2; return; }
  if (atomic_load_explicit(&w->recpg->gen, memory_order_acquire) != w->recgen) {
    e->count = 0;                           /* page changed while recording */
    return;
  }
  size_t len = EmitModule(w);
  long slot = len ? syscall(NR_LOT_WASM_LOAD, w->code, len) : -1;
  if (slot <= 0) {
    if (errno == ENOSYS || errno == ENOSPC) g_wj_mode = 0;   /* runtime can't */
    e->state = 2;
    s_failed++;
    return;
  }
  e->slot = (u32)slot;
  e->pg = w->recpg;
  e->gen = w->recgen;
  e->state = 1;
  w->nfns++;
  s_blocks++;
  s_opsum += w->nops;
}

/* Runs one instruction or one translated block. */
void WasmJitDispatch(struct Machine *m) {
  struct Wj *w;
  if (!WjEnabled() || !(w = WjGet())) {
    JitlessDispatch(DISPATCH_NOTHING);
    return;
  }
  u64 pc = m->ip;
  if (!w->rec && w->atstart) {
    struct WjEntry *e = WjFind(w, pc);
    if (e) {
      if (e->state == 1) {
        if (atomic_load_explicit(&e->pg->gen, memory_order_acquire) == e->gen) {
          s_calls++;
          ((nexgen32e_f)(uintptr_t)e->slot)(DISPATCH_NOTHING);
          return;                           /* atstart stays true */
        }
        e->state = 0;                       /* its page changed: count again */
        e->count = 0;
      }
      if (e->state == 0 && ++e->count == g_wj_hot) {
        struct WjPage *pg = 0;
        if (WjTranslatable(m, pc)) {
          WjLock();
          pg = WjPageLocked(pc & -4096, true);
          WjUnlock();
        }
        if (pg) {
          w->recpg = pg;
          w->recgen = atomic_load_explicit(&pg->gen, memory_order_acquire);
          w->rec = true;
          w->start = w->next = pc;
          w->nops = 0;
        } else {
          e->state = 2;
        }
      }
    }
  }
  s_interp++;
  LoadInstruction(m, GetPc(m));
  u64 rde = m->xedd->op.rde;
  i64 disp = m->xedd->op.disp;
  u64 uimm0 = m->xedd->op.uimm0;
  int cls = ClassifyOp(rde);
  int len = Oplength(rde);
  bool added = false;
  if (w->rec) {
    long mop = Mopcode(rde);
    if (pc != w->next) {
      w->rec = false;                       /* control left the block: drop */
    } else if (cls == kOpPrecious || w->nops == WJ_MAXOPS ||
               ((pc & 4095) + len > 4096) ||
               (pc & -4096) != (w->start & -4096) ||
               mop == 0xD4 || mop == 0xD5) {
      WjFinish(m, w);                       /* this op stays interpreted */
    } else {
      struct WjOp *o = &w->ops[w->nops++];
      o->rde = rde;
      o->disp = disp;
      o->uimm0 = uimm0;
      o->fn = (u32)(uintptr_t)GetOp(mop);
      o->len = len;
      w->next = pc + len;
      added = true;
    }
  }
  w->atstart = false;
  m->oplen = len;
  m->ip += len;
  GetOp(Mopcode(rde))(m, rde, disp, uimm0);
  if (m->stashaddr) CommitStash(m);
  m->oplen = 0;
  if (cls != kOpNormal) w->atstart = true;
  if (added && cls == kOpBranching) WjFinish(m, w);
}

#endif /* LOT_WASMJIT */

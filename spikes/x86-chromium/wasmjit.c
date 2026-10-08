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
 * The most common integer ops are emitted inline instead of calling their
 * handler (WjInline): 32/64-bit register forms of mov, add/or/and/sub/xor,
 * cmp/test (register and immediate), mov reg,imm, lea, jcc and jmp. They
 * can't fault, so they skip the ip/oplen bookkeeping; flags are computed
 * the way blink/alu.c does (CF ZF SF OF AF, and the result's low byte in
 * bits 24-31 for PF), so handler ops that follow read the same state.
 *
 * What it does not do (yet): memory operands inline, chain blocks, batch
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
#include "blink/flags.h"
#include "blink/modrm.h"
#include "blink/x86.h"

#define NR_LOT_WASM_LOAD 10001
#define WJ_HOT    256         /* block starts before translating (BLINK_WASMJIT_HOT): a
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
static long s_blocks, s_failed, s_calls, s_flushes, s_opsum, s_interp, s_inlined;
static bool g_wj_stats;

static void WjLock(void) {
  int z = 0;
  while (!atomic_compare_exchange_weak(&g_wj_lock, &z, 1)) z = 0;
}
static void WjUnlock(void) { atomic_store(&g_wj_lock, 0); }

void WasmJitAtExit(void) {
  if (!g_wj_stats) return;
  fprintf(stderr,
          "[wasmjit] blocks=%ld (avg %.1f ops, %ld inline) failed=%ld "
          "block-calls=%ld interpreted=%ld flushes=%ld\n",
          s_blocks, s_blocks ? (double)s_opsum / s_blocks : 0.0, s_inlined,
          s_failed, s_calls, s_interp, s_flushes);
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
enum { LGET = 0x20, LSET = 0x21, I32C = 0x41, I64C = 0x42, I64LD = 0x29,
       I64ST = 0x37, I32ST8 = 0x3a, I64NE = 0x52, I64EQZ = 0x50, IF = 0x04,
       END = 0x0b, RET = 0x0f, CALLI = 0x11, EQZ32 = 0x45, LOOP = 0x03,
       I64EQ = 0x51, I32AND = 0x71, BRIF = 0x0d, I32LD8U = 0x2d,
       I32LD = 0x28, I32ST = 0x36, I64LD32U = 0x35, I64LTU = 0x54,
       I64ADD = 0x7c, I64SUB = 0x7d, I64AND = 0x83, I64OR = 0x84,
       I64XOR = 0x85, I64SHL = 0x86, I64SHRU = 0x88, I32WRAP = 0xa7,
       I32OR = 0x72, I32XOR = 0x73, I32SHL = 0x74, I32SHRU = 0x76,
       SELECT = 0x1b };

/* function locals after the 4 params: three i64 scratch values, one i32 */
enum { LX = 4, LY = 5, LZ = 6, LF = 7 };

static void Mem(struct Wj *w, size_t *n, u8 op, u32 align, u32 off) {
  B(w, n, op); U(w, n, align); U(w, n, off);
}


/* ── inline ops ─────────────────────────────────────────────────────────── */
static u32 OREG, OFLAGS;

static void Op(struct Wj *w, size_t *n, u8 op) { B(w, n, op); }
static void Get(struct Wj *w, size_t *n, u32 l) { B(w, n, LGET); U(w, n, l); }
static void Set(struct Wj *w, size_t *n, u32 l) { B(w, n, LSET); U(w, n, l); }
static void K64(struct Wj *w, size_t *n, i64 v) { B(w, n, I64C); S(w, n, v); }
static void K32(struct Wj *w, size_t *n, i32 v) { B(w, n, I32C); S(w, n, v); }

/* push register r (zero-extended to i64 when 32-bit) */
static void LoadReg(struct Wj *w, size_t *n, int r, int bits) {
  Get(w, n, 0);
  if (bits == 64) Mem(w, n, I64LD, 3, OREG + 8 * r);
  else Mem(w, n, I64LD32U, 2, OREG + 8 * r);
}
/* register r = local l (already zero-extended for 32-bit writes) */
static void StoreRegFrom(struct Wj *w, size_t *n, int r, u32 l) {
  Get(w, n, 0); Get(w, n, l); Mem(w, n, I64ST, 3, OREG + 8 * r);
}

enum { K_ADD = 0, K_OR = 1, K_AND = 4, K_SUB = 5, K_XOR = 6, K_CMP = 7, K_TEST = 8 };

/* x (reg) op y (reg, or imm when yr < 0); result to dst unless dst < 0 */
static void EmitAlu(struct Wj *w, size_t *n, int kind, int bits, int xr, int yr,
                    u64 imm, int dst) {
  u64 mask = bits == 64 ? ~0ull : 0xffffffffull;
  bool arith = kind == K_ADD || kind == K_SUB || kind == K_CMP;
  bool sub = kind == K_SUB || kind == K_CMP;
  LoadReg(w, n, xr, bits); Set(w, n, LX);
  if (yr >= 0) LoadReg(w, n, yr, bits);
  else K64(w, n, (i64)(imm & mask));
  Set(w, n, LY);
  Get(w, n, LX); Get(w, n, LY);
  switch (kind) {
    case K_ADD: Op(w, n, I64ADD); break;
    case K_SUB: case K_CMP: Op(w, n, I64SUB); break;
    case K_AND: case K_TEST: Op(w, n, I64AND); break;
    case K_OR: Op(w, n, I64OR); break;
    case K_XOR: Op(w, n, I64XOR); break;
  }
  if (bits == 32) { K64(w, n, 0xffffffff); Op(w, n, I64AND); }
  Set(w, n, LZ);
  if (dst >= 0) StoreRegFrom(w, n, dst, LZ);
  /* m->flags = (m->flags & ~(CF|ZF|SF|OF|AF|0xff000000)) | ... */
  Get(w, n, 0);
  Get(w, n, 0); Mem(w, n, I32LD, 2, OFLAGS);
  K32(w, n, (i32) ~(u32)(CF | ZF | SF | OF | AF | 0xFF000000u)); Op(w, n, I32AND);
  Get(w, n, LZ); K64(w, n, bits - 1); Op(w, n, I64SHRU); Op(w, n, I32WRAP);
  K32(w, n, 1); Op(w, n, I32AND); K32(w, n, FLAGS_SF); Op(w, n, I32SHL); Op(w, n, I32OR);
  Get(w, n, LZ); Op(w, n, I64EQZ); K32(w, n, FLAGS_ZF); Op(w, n, I32SHL); Op(w, n, I32OR);
  Get(w, n, LZ); Op(w, n, I32WRAP); K32(w, n, 24); Op(w, n, I32SHL); Op(w, n, I32OR);
  if (arith) {
    /* cf: add z < y, sub x < z */
    if (sub) { Get(w, n, LX); Get(w, n, LZ); } else { Get(w, n, LZ); Get(w, n, LY); }
    Op(w, n, I64LTU); Op(w, n, I32OR);
    /* af: add (z&15) < (y&15), sub (x&15) < (z&15) */
    if (sub) { Get(w, n, LX); K64(w, n, 15); Op(w, n, I64AND); Get(w, n, LZ); }
    else { Get(w, n, LZ); K64(w, n, 15); Op(w, n, I64AND); Get(w, n, LY); }
    K64(w, n, 15); Op(w, n, I64AND); Op(w, n, I64LTU);
    K32(w, n, FLAGS_AF); Op(w, n, I32SHL); Op(w, n, I32OR);
    /* of: add ((z^x)&(z^y)), sub ((x^y)&(z^x)), top bit */
    if (sub) {
      Get(w, n, LX); Get(w, n, LY); Op(w, n, I64XOR);
      Get(w, n, LZ); Get(w, n, LX); Op(w, n, I64XOR);
    } else {
      Get(w, n, LZ); Get(w, n, LX); Op(w, n, I64XOR);
      Get(w, n, LZ); Get(w, n, LY); Op(w, n, I64XOR);
    }
    Op(w, n, I64AND); K64(w, n, bits - 1); Op(w, n, I64SHRU); Op(w, n, I32WRAP);
    K32(w, n, 1); Op(w, n, I32AND); K32(w, n, FLAGS_OF); Op(w, n, I32SHL); Op(w, n, I32OR);
  }
  Mem(w, n, I32ST, 2, OFLAGS);
}

/* push the condition (i32 0/1) of jcc code 0..15 (not 0xA/0xB), from the
   flags the way blink/uop.c's Jo..Jg read them */
static void Bit(struct Wj *w, size_t *n, int flag) {  /* (f >> flag) & 1 */
  Get(w, n, LF); K32(w, n, flag); Op(w, n, I32SHRU); K32(w, n, 1); Op(w, n, I32AND);
}
static void EmitCond(struct Wj *w, size_t *n, int code) {
  Get(w, n, 0); Mem(w, n, I32LD, 2, OFLAGS); Set(w, n, LF);
  switch (code & ~1) {
    case 0x0: Bit(w, n, FLAGS_OF); break;                       /* o */
    case 0x2: Bit(w, n, FLAGS_CF); break;                       /* b */
    case 0x4: Bit(w, n, FLAGS_ZF); break;                       /* e */
    case 0x6: Bit(w, n, FLAGS_CF); Bit(w, n, FLAGS_ZF); Op(w, n, I32OR); break; /* be */
    case 0x8: Bit(w, n, FLAGS_SF); break;                       /* s */
    case 0xC: Bit(w, n, FLAGS_SF); Bit(w, n, FLAGS_OF); Op(w, n, I32XOR); break; /* l */
    case 0xE: Bit(w, n, FLAGS_SF); Bit(w, n, FLAGS_OF); Op(w, n, I32XOR);       /* le */
              Bit(w, n, FLAGS_ZF); Op(w, n, I32OR); break;
  }
  if (code & 1) Op(w, n, EQZ32);                                /* the negation */
}

/* Emits op o inline if it is one we know; pcnext = address after it.
   *setsip: it wrote m->ip (jcc/jmp). */
static bool WjInline(struct Wj *w, size_t *n, struct WjOp *o, u64 pcnext,
                     bool *setsip) {
  u64 rde = o->rde;
  long mop = Mopcode(rde);
  int lg = RegLog2(rde), bits = lg == 3 ? 64 : 32;
  bool word = (lg == 3 || lg == 2) && !Osz(rde) && Mode(rde) == XED_MODE_LONG;
  bool regf = IsModrmRegister(rde);
  *setsip = false;
  switch (mop) {
    case 0x01: case 0x09: case 0x21: case 0x29: case 0x31: {   /* Ev op= Gv */
      if (!word || !regf || Lock(rde)) return false;
      EmitAlu(w, n, (Opcode(rde) & 070) >> 3, bits, RexbRm(rde), RexrReg(rde), 0, RexbRm(rde));
      return true;
    }
    case 0x03: case 0x0B: case 0x23: case 0x2B: case 0x33: {   /* Gv op= Ev */
      if (!word || !regf) return false;
      EmitAlu(w, n, (Opcode(rde) & 070) >> 3, bits, RexrReg(rde), RexbRm(rde), 0, RexrReg(rde));
      return true;
    }
    case 0x39:                                                   /* cmp Ev, Gv */
      if (!word || !regf) return false;
      EmitAlu(w, n, K_CMP, bits, RexbRm(rde), RexrReg(rde), 0, -1);
      return true;
    case 0x3B:                                                   /* cmp Gv, Ev */
      if (!word || !regf) return false;
      EmitAlu(w, n, K_CMP, bits, RexrReg(rde), RexbRm(rde), 0, -1);
      return true;
    case 0x85:                                                   /* test Ev, Gv */
      if (!word || !regf) return false;
      EmitAlu(w, n, K_TEST, bits, RexbRm(rde), RexrReg(rde), 0, -1);
      return true;
    case 0x81: case 0x83: {                                      /* op Ev, imm */
      int k = ModrmReg(rde);
      if (!word || !regf || Lock(rde) || k == 2 || k == 3) return false;
      EmitAlu(w, n, k, bits, RexbRm(rde), -1, o->uimm0, k == K_CMP ? -1 : RexbRm(rde));
      return true;
    }
    case 0x89:                                                   /* mov Ev, Gv */
    case 0x8B: {                                                 /* mov Gv, Ev */
      if (!word || !regf) return false;
      int src = mop == 0x89 ? RexrReg(rde) : RexbRm(rde);
      int dst = mop == 0x89 ? RexbRm(rde) : RexrReg(rde);
      LoadReg(w, n, src, bits); Set(w, n, LZ);
      StoreRegFrom(w, n, dst, LZ);
      return true;
    }
    case 0xB8: case 0xB9: case 0xBA: case 0xBB:                  /* mov r, imm */
    case 0xBC: case 0xBD: case 0xBE: case 0xBF: {
      if (!word) return false;
      K64(w, n, (i64)(bits == 64 ? o->uimm0 : (u32)o->uimm0)); Set(w, n, LZ);
      StoreRegFrom(w, n, RexbSrm(rde), LZ);
      return true;
    }
    case 0x8D: {                                                 /* lea Gv, M */
      int ea = Eamode(rde);
      if (!word || regf || (ea != XED_MODE_LONG && ea != XED_MODE_LEGACY)) return false;
      if (!SibExists(rde)) {
        if (IsRipRelative(rde)) {
          K64(w, n, (i64)(pcnext + (u64)o->disp));
        } else {
          K64(w, n, o->disp);
          LoadReg(w, n, RexbRm(rde), 64); Op(w, n, I64ADD);
        }
      } else {
        K64(w, n, o->disp);
        if (SibHasBase(rde)) { LoadReg(w, n, RexbBase(rde), 64); Op(w, n, I64ADD); }
        if (SibHasIndex(rde)) {
          LoadReg(w, n, Rexx(rde) << 3 | SibIndex(rde), 64);
          K64(w, n, SibScale(rde)); Op(w, n, I64SHL); Op(w, n, I64ADD);
        }
      }
      if (ea == XED_MODE_LEGACY || bits == 32) { K64(w, n, 0xffffffff); Op(w, n, I64AND); }
      Set(w, n, LZ);
      StoreRegFrom(w, n, RexrReg(rde), LZ);
      return true;
    }
    case 0xEB: case 0xE9:                                        /* jmp rel */
      if (Mode(rde) != XED_MODE_LONG) return false;
      Get(w, n, 0); K64(w, n, (i64)(pcnext + (u64)o->disp));
      Mem(w, n, I64ST, 3, offsetof(struct Machine, ip));
      *setsip = true;
      return true;
    default:
      if (((mop >= 0x70 && mop <= 0x7F) || (mop >= 0x180 && mop <= 0x18F)) &&
          (mop & 15) != 0xA && (mop & 15) != 0xB && Mode(rde) == XED_MODE_LONG) {
        Get(w, n, 0);
        K64(w, n, (i64)(pcnext + (u64)o->disp));
        K64(w, n, (i64)pcnext);
        EmitCond(w, n, mop & 15);
        Op(w, n, SELECT);
        Mem(w, n, I64ST, 3, offsetof(struct Machine, ip));
        *setsip = true;
        return true;
      }
      return false;
  }
}

static void EmitBody(struct Wj *w, size_t *n) {
  const u32 OIP = offsetof(struct Machine, ip);
  const u32 OLEN = offsetof(struct Machine, oplen);
  const u32 OSTASH = offsetof(struct Machine, stashaddr);
  const u32 COMMIT = (u32)(uintptr_t)CommitStash;
  const u32 OATT = offsetof(struct Machine, attention);
  u64 pc = w->start;
  bool ipset = true;      /* m->ip holds the right value at this point */
  OREG = offsetof(struct Machine, weg);
  OFLAGS = offsetof(struct Machine, flags);
  /* locals: 3 x i64 (LX LY LZ), 1 x i32 (LF) */
  B(w, n, 2); B(w, n, 3); B(w, n, 0x7e); B(w, n, 1); B(w, n, 0x7f);
  B(w, n, LOOP); B(w, n, 0x40);
  for (int i = 0; i < w->nops; i++) {
    struct WjOp *o = &w->ops[i];
    bool setsip;
    pc += o->len;
    if (WjInline(w, n, o, pc, &setsip)) {
      ipset = setsip;
      s_inlined++;
      continue;
    }
    ipset = true;
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
  if (!ipset) {   /* ended on an inline op that left m->ip behind */
    B(w, n, LGET); U(w, n, 0); B(w, n, I64C); S(w, n, (i64)pc); Mem(w, n, I64ST, 3, OIP);
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

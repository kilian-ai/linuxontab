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
 * handler (WjInline): mov, the ALU ops, cmp/test, inc/dec, movzx/movsx, lea,
 * push/pop, jcc/jmp, call/ret and call/jmp/push through a register or
 * memory, at 8 to 64 bits. They
 * can't fault, so they skip the ip/oplen bookkeeping; flags are computed
 * the way blink/alu.c does (CF ZF SF OF AF, and the result's low byte in
 * bits 24-31 for PF), so handler ops that follow read the same state.
 *
 * Memory operands of those ops (and push/pop) take Blink's TLB fast path in
 * wasm: tlb[(page >> 12) & 31] must hold the page with V|U|HOST (+RW for a
 * write), the TLB must not be invalidated, and the access must not cross
 * the page; the host address is then g_hostpages.p[entry >> 12] + offset
 * (FindHostPage). Anything else — a miss, a fault, a copy-on-write page, a
 * page-crossing access — calls the op's handler instead, which does it the
 * usual way. ip/oplen are stored first so that handler can fault.
 *
 * What it does not do (yet): chain blocks, batch several blocks into one
 * module, compile off the hot path.
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
 * Blocks chain: each translation owns two successor cells (WjExits) in
 * linear memory, {pc, slot, epoch}. At its end a block compares m->ip with
 * them and, when one matches, the chain epoch is current, m->attention is
 * clear and the per-thread depth is under WJ_MAXDEPTH, calls that block
 * directly; otherwise it leaves its cells in w->lastexit and returns, and
 * the dispatcher links the next translated block it finds into a free cell.
 * Cells are keyed by pc, so any link is correct; a translated page changing
 * bumps the chain epoch, which retires every link at once. Calls nest (no
 * tail calls), so a chain returns to the dispatcher every WJ_MAXDEPTH
 * blocks; the dispatcher resets the depth, which a fault's longjmp skips.
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
#define WJ_MAXDEPTH 128       /* chained calls before returning to the dispatcher */

struct WjExits {              /* a block's successor cells (see EmitChain) */
  u64 pc[2];
  u32 slot[2];
  u32 epoch[2];
  u32 next;                   /* which cell to replace when both are used */
};

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
  struct WjExits *lastexit;   /* written by blocks that didn't chain */
  u32 depth;                  /* chained-call depth (read/written by blocks) */
  struct WjExits *curexits;   /* the block being emitted */
};

static _Thread_local struct Wj *g_wj;
static _Atomic(u32) g_wj_chain = 1;        /* chain epoch: links made in another are dead */
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
static long s_blocks, s_failed, s_calls, s_flushes, s_opsum, s_interp, s_inlined, s_links;
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
          "block-calls=%ld interpreted=%ld links=%ld flushes=%ld\n",
          s_blocks, s_blocks ? (double)s_opsum / s_blocks : 0.0, s_inlined,
          s_failed, s_calls, s_interp, s_links, s_flushes);
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
    atomic_fetch_add_explicit(&g_wj_chain, 1, memory_order_release);
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
       SELECT = 0x1b, ELSE = 0x05, LTEE = 0x22, I64LEU = 0x58,
       I32ADD = 0x6a, I32MUL = 0x6c, I32NE = 0x47, I64ST32 = 0x3e,
       I64LD8U = 0x31, I64LD16U = 0x33, I64ST8 = 0x3c, I64ST16 = 0x3d,
       I64EXT8S = 0xc2, I64EXT16S = 0xc3, I64EXT32S = 0xc4,
       I32EQ = 0x46, I32LTU = 0x49, I32SUB = 0x6b };

/* function locals after the 4 params: five i64 scratch values (operands,
   result, effective address, TLB entry), four i32 (flags, TLB slot address,
   host page, host address) */
enum { LX = 4, LY = 5, LZ = 6, LA = 7, LE = 8, LF = 9, LT = 10, LP = 11, LH = 12 };

static void Mem(struct Wj *w, size_t *n, u8 op, u32 align, u32 off) {
  B(w, n, op); U(w, n, align); U(w, n, off);
}


/* ── inline ops ─────────────────────────────────────────────────────────── */
/* Operands are 8, 16, 32 or 64 bits wide. Registers are named by their byte
   offset in struct Machine: a word register r is weg[r]; a byte register
   comes from Blink's kByteReg table (AH..BH without a REX prefix), so the
   offsets match ByteRexrReg/ByteRexbRm exactly. Writes follow
   WriteRegister: 64 and 32 store all 8 bytes (32 zero-extended), 16 and 8
   store just their bytes. */
static u32 OREG, OFLAGS;

static void Op(struct Wj *w, size_t *n, u8 op) { B(w, n, op); }
static void Get(struct Wj *w, size_t *n, u32 l) { B(w, n, LGET); U(w, n, l); }
static void Set(struct Wj *w, size_t *n, u32 l) { B(w, n, LSET); U(w, n, l); }
static void K64(struct Wj *w, size_t *n, i64 v) { B(w, n, I64C); S(w, n, v); }
static void K32(struct Wj *w, size_t *n, i32 v) { B(w, n, I32C); S(w, n, v); }

static int RW(int r) { return (int)(OREG + 8 * r); }            /* weg[r] */
static int RB(int k) { return (int)(OREG + kByteReg[k]); }      /* byte reg, k = RexRex*() */
static u64 Mask(int bits) { return bits == 64 ? ~0ull : (1ull << bits) - 1; }

/* push the register at offset off, zero-extended to i64 */
static void LoadReg(struct Wj *w, size_t *n, int off, int bits) {
  Get(w, n, 0);
  switch (bits) {
    case 64: Mem(w, n, I64LD, 3, off); break;
    case 32: Mem(w, n, I64LD32U, 2, off); break;
    case 16: Mem(w, n, I64LD16U, 1, off); break;
    default: Mem(w, n, I64LD8U, 0, off); break;
  }
}
/* register at offset off = local l (zero-extended already) */
static void StoreRegFrom(struct Wj *w, size_t *n, int off, u32 l, int bits) {
  Get(w, n, 0); Get(w, n, l);
  switch (bits) {
    case 64: case 32: Mem(w, n, I64ST, 3, off); break;
    case 16: Mem(w, n, I64ST16, 1, off); break;
    default: Mem(w, n, I64ST8, 0, off); break;
  }
}

enum { K_ADD = 0, K_OR = 1, K_AND = 4, K_SUB = 5, K_XOR = 6, K_CMP = 7,
       K_TEST = 8, K_INC = 10, K_DEC = 11 };
enum { SRC_IMM = -1, SRC_PRE = -2 };   /* operand: imm / already in LX|LY */
enum { DST_NONE = -1, DST_MEM = -2 };  /* result: dropped / stored at LH */

static void StoreMem(struct Wj *w, size_t *n, int bits, u32 l) {
  Get(w, n, LH); Get(w, n, l);
  switch (bits) {
    case 64: Mem(w, n, I64ST, 0, 0); break;
    case 32: Mem(w, n, I64ST32, 0, 0); break;
    case 16: Mem(w, n, I64ST16, 0, 0); break;
    default: Mem(w, n, I64ST8, 0, 0); break;
  }
}
/* local l = the memory operand at LH, zero-extended */
static void LoadMem(struct Wj *w, size_t *n, int bits, u32 l) {
  Get(w, n, LH);
  switch (bits) {
    case 64: Mem(w, n, I64LD, 0, 0); break;
    case 32: Mem(w, n, I64LD32U, 0, 0); break;
    case 16: Mem(w, n, I64LD16U, 0, 0); break;
    default: Mem(w, n, I64LD8U, 0, 0); break;
  }
  Set(w, n, l);
}

/* x op y, flags as blink/alu.c computes them. x is a register offset or
   SRC_PRE (LX set); y a register offset, SRC_IMM or SRC_PRE (LY set); the
   result goes to a register offset, DST_MEM or nowhere. INC/DEC ignore y
   and keep CF (BumpFlags); like Blink's, INC's AF is always 0 and both use
   (z^1)/(x^1) in their OF terms. */
static void EmitAlu(struct Wj *w, size_t *n, int kind, int bits, int xr, int yr,
                    u64 imm, int dst) {
  u64 mask = Mask(bits);
  bool bump = kind == K_INC || kind == K_DEC;
  bool arith = kind == K_ADD || kind == K_SUB || kind == K_CMP;
  bool sub = kind == K_SUB || kind == K_CMP;
  if (xr >= 0) { LoadReg(w, n, xr, bits); Set(w, n, LX); }
  if (bump) { K64(w, n, 1); Set(w, n, LY); }
  else if (yr != SRC_PRE) {
    if (yr >= 0) LoadReg(w, n, yr, bits);
    else K64(w, n, (i64)(imm & mask));
    Set(w, n, LY);
  }
  Get(w, n, LX); Get(w, n, LY);
  switch (kind) {
    case K_ADD: case K_INC: Op(w, n, I64ADD); break;
    case K_SUB: case K_CMP: case K_DEC: Op(w, n, I64SUB); break;
    case K_AND: case K_TEST: Op(w, n, I64AND); break;
    case K_OR: Op(w, n, I64OR); break;
    case K_XOR: Op(w, n, I64XOR); break;
  }
  if (bits < 64) { K64(w, n, (i64)mask); Op(w, n, I64AND); }
  Set(w, n, LZ);
  if (dst >= 0) StoreRegFrom(w, n, dst, LZ, bits);
  else if (dst == DST_MEM) StoreMem(w, n, bits, LZ);
  /* m->flags = (m->flags & ~(ZF|SF|OF|AF|0xff000000 [|CF])) | ... */
  Get(w, n, 0);
  Get(w, n, 0); Mem(w, n, I32LD, 2, OFLAGS);
  K32(w, n, (i32) ~(u32)(ZF | SF | OF | AF | 0xFF000000u | (bump ? 0 : CF)));
  Op(w, n, I32AND);
  Get(w, n, LZ); K64(w, n, bits - 1); Op(w, n, I64SHRU); Op(w, n, I32WRAP);
  K32(w, n, 1); Op(w, n, I32AND); K32(w, n, FLAGS_SF); Op(w, n, I32SHL); Op(w, n, I32OR);
  Get(w, n, LZ); Op(w, n, I64EQZ); K32(w, n, FLAGS_ZF); Op(w, n, I32SHL); Op(w, n, I32OR);
  Get(w, n, LZ); Op(w, n, I32WRAP); K32(w, n, 24); Op(w, n, I32SHL); Op(w, n, I32OR);
  if (arith) {
    /* cf: add z < y, sub x < z */
    if (sub) { Get(w, n, LX); Get(w, n, LZ); } else { Get(w, n, LZ); Get(w, n, LY); }
    Op(w, n, I64LTU); Op(w, n, I32OR);
  }
  if (arith || kind == K_DEC) {
    /* af: add (z&15) < (y&15), sub/dec (x&15) < (z&15); inc: 0 */
    if (sub || kind == K_DEC) { Get(w, n, LX); K64(w, n, 15); Op(w, n, I64AND); Get(w, n, LZ); }
    else { Get(w, n, LZ); K64(w, n, 15); Op(w, n, I64AND); Get(w, n, LY); }
    K64(w, n, 15); Op(w, n, I64AND); Op(w, n, I64LTU);
    K32(w, n, FLAGS_AF); Op(w, n, I32SHL); Op(w, n, I32OR);
  }
  if (arith || bump) {
    /* of: add (z^x)&(z^y), sub (x^y)&(z^x), inc (z^x)&(z^1), dec (z^x)&(x^1) */
    if (sub) {
      Get(w, n, LX); Get(w, n, LY); Op(w, n, I64XOR);
      Get(w, n, LZ); Get(w, n, LX); Op(w, n, I64XOR);
    } else if (kind == K_DEC) {
      Get(w, n, LZ); Get(w, n, LX); Op(w, n, I64XOR);
      Get(w, n, LX); K64(w, n, 1); Op(w, n, I64XOR);
    } else {      /* add, inc (LY = 1) */
      Get(w, n, LZ); Get(w, n, LX); Op(w, n, I64XOR);
      Get(w, n, LZ); Get(w, n, LY); Op(w, n, I64XOR);
    }
    Op(w, n, I64AND); K64(w, n, bits - 1); Op(w, n, I64SHRU); Op(w, n, I32WRAP);
    K32(w, n, 1); Op(w, n, I32AND); K32(w, n, FLAGS_OF); Op(w, n, I32SHL); Op(w, n, I32OR);
  }
  Mem(w, n, I32ST, 2, OFLAGS);
}

/* ── memory operands ─────────────────────────────────────────────────────── */
static u32 OTLB, OINV, OSEGB[8];
static u32 HOSTPAGES;                 /* address of g_hostpages.p */

static bool MemOk(u64 rde) {
  int ea = Eamode(rde);
  return !IsModrmRegister(rde) && Mode(rde) == XED_MODE_LONG &&
         (ea == XED_MODE_LONG || ea == XED_MODE_LEGACY);
}

/* LA = ComputeAddress(): LoadEffectiveAddress() + segment base */
static void EmitEa(struct Wj *w, size_t *n, struct WjOp *o, u64 pcnext) {
  u64 rde = o->rde;
  int seg = 3;                                     /* DS (seg[] index) */
  if (!SibExists(rde)) {
    if (IsRipRelative(rde)) {
      K64(w, n, (i64)(pcnext + (u64)o->disp));
    } else {
      K64(w, n, o->disp);
      LoadReg(w, n, RW(RexbRm(rde)), 64); Op(w, n, I64ADD);
      if (RexbRm(rde) == 4 || RexbRm(rde) == 5) seg = 2;       /* SS */
    }
  } else {
    K64(w, n, o->disp);
    if (SibHasBase(rde)) {
      LoadReg(w, n, RW(RexbBase(rde)), 64); Op(w, n, I64ADD);
      if (RexbBase(rde) == 4 || RexbBase(rde) == 5) seg = 2;
    }
    if (SibHasIndex(rde)) {
      LoadReg(w, n, RW(Rexx(rde) << 3 | SibIndex(rde)), 64);
      K64(w, n, SibScale(rde)); Op(w, n, I64SHL); Op(w, n, I64ADD);
    }
  }
  if (Eamode(rde) == XED_MODE_LEGACY) { K64(w, n, 0xffffffff); Op(w, n, I64AND); }
  if (Sego(rde)) seg = Sego(rde) - 1;
  Get(w, n, 0); Mem(w, n, I64LD, 3, OSEGB[seg]); Op(w, n, I64ADD);
  Set(w, n, LA);
}

/* LH = host address of [LA, LA+size) through the TLB, or 0 */
static void EmitXlat(struct Wj *w, size_t *n, int size, bool write) {
  u64 need = PAGE_V | PAGE_U | PAGE_HOST | (write ? PAGE_RW : 0);
  /* LT = m + ((LA >> 12) & 31) * 16 */
  Get(w, n, 0);
  Get(w, n, LA); K64(w, n, 12); Op(w, n, I64SHRU); Op(w, n, I32WRAP);
  K32(w, n, 31); Op(w, n, I32AND); K32(w, n, 16); Op(w, n, I32MUL); Op(w, n, I32ADD);
  Set(w, n, LT);
  Get(w, n, LT); Mem(w, n, I64LD, 3, OTLB + 8); Set(w, n, LE);
  /* tlb.page == (LA & -4096) */
  Get(w, n, LT); Mem(w, n, I64LD, 3, OTLB);
  Get(w, n, LA); K64(w, n, -4096); Op(w, n, I64AND); Op(w, n, I64EQ);
  /* (entry & need) == need */
  Get(w, n, LE); K64(w, n, (i64)need); Op(w, n, I64AND); K64(w, n, (i64)need); Op(w, n, I64EQ);
  Op(w, n, I32AND);
  /* (LA & 4095) <= 4096 - size */
  Get(w, n, LA); K64(w, n, 4095); Op(w, n, I64AND); K64(w, n, 4096 - size); Op(w, n, I64LEU);
  Op(w, n, I32AND);
  /* !m->invalidated */
  Get(w, n, 0); Mem(w, n, I32LD8U, 0, OINV); Op(w, n, EQZ32);
  Op(w, n, I32AND);
  B(w, n, IF); B(w, n, 0x7f);
    /* LP = g_hostpages.p[(entry & PAGE_TA) >> 12] */
    K32(w, n, (i32)HOSTPAGES); Mem(w, n, I32LD, 2, 0);
    Get(w, n, LE); K64(w, n, (i64)PAGE_TA); Op(w, n, I64AND); K64(w, n, 12); Op(w, n, I64SHRU);
    Op(w, n, I32WRAP); K32(w, n, 2); Op(w, n, I32SHL); Op(w, n, I32ADD);
    Mem(w, n, I32LD, 2, 0); B(w, n, LTEE); U(w, n, LP);
    /* LP ? LP + (LA & 4095) : 0 */
    Get(w, n, LA); Op(w, n, I32WRAP); K32(w, n, 4095); Op(w, n, I32AND); Op(w, n, I32ADD);
    K32(w, n, 0);
    Get(w, n, LP); K32(w, n, 0); Op(w, n, I32NE);
    Op(w, n, SELECT);
  B(w, n, ELSE);
    K32(w, n, 0);
  B(w, n, END);
  Set(w, n, LH);
}

static void EmitHandler(struct Wj *w, size_t *n, struct WjOp *o, u64 pc, bool prologue);

/* prologue, address, TLB; then `if (LH)` — the caller emits the fast path */
static void MemBegin(struct Wj *w, size_t *n, struct WjOp *o, u64 pc, int size,
                     bool write, bool ea) {
  Get(w, n, 0); K64(w, n, (i64)pc); Mem(w, n, I64ST, 3, offsetof(struct Machine, ip));
  Get(w, n, 0); K32(w, n, o->len); Mem(w, n, I32ST8, 0, offsetof(struct Machine, oplen));
  if (ea) EmitEa(w, n, o, pc);
  EmitXlat(w, n, size, write);
  Get(w, n, LH); B(w, n, IF); B(w, n, 0x40);
}
/* `else` the op's handler `end` */
static void MemEnd(struct Wj *w, size_t *n, struct WjOp *o, u64 pc) {
  B(w, n, ELSE);
  EmitHandler(w, n, o, pc, false);
  B(w, n, END);
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

/* m->ip = local l */
static void SetIpFrom(struct Wj *w, size_t *n, u32 l) {
  Get(w, n, 0); Get(w, n, l); Mem(w, n, I64ST, 3, offsetof(struct Machine, ip));
}
/* push the 64-bit local l (PushN in long mode: rsp -= 8, then the store),
   then m->ip = local ipl unless ipl < 0; the handler on a TLB miss */
static void PushFast(struct Wj *w, size_t *n, struct WjOp *o, u64 pc, u32 l, int ipl) {
  LoadReg(w, n, RW(4), 64); K64(w, n, 8); Op(w, n, I64SUB); Set(w, n, LA);
  MemBegin(w, n, o, pc, 8, true, false);
    StoreRegFrom(w, n, RW(4), LA, 64);
    StoreMem(w, n, 64, l);
    if (ipl >= 0) SetIpFrom(w, n, ipl);
  MemEnd(w, n, o, pc);
}

/* An operand of an Eb/Ev op: a register offset, or memory (MEM). */
#define MEM (-100)

/* Width of the Ev/Gv operand: 64 with REX.W, 16 with 0x66, else 32. */
static int WordBits(u64 rde) { return Rexw(rde) ? 64 : Osz(rde) ? 16 : 32; }

/* Emits op o inline if it is one we know; pcnext = address after it.
   *setsip: m->ip is valid afterwards (jcc/jmp, or a memory op's prologue). */
static bool WjInline(struct Wj *w, size_t *n, struct WjOp *o, u64 pcnext,
                     bool *setsip) {
  u64 rde = o->rde;
  long mop = Mopcode(rde);
  bool lng = Mode(rde) == XED_MODE_LONG;
  bool regf = IsModrmRegister(rde);
  int wb = WordBits(rde);
  *setsip = false;
  if (!lng || Lock(rde)) return false;
  bool memok = MemOk(rde);   /* a memory operand we can address inline */
  /* operand descriptors for the modrm forms */
  int erm = regf ? RW(RexbRm(rde)) : MEM;          /* Ev */
  int brm = regf ? RB(RexRexb(rde)) : MEM;         /* Eb */
  int ereg = RW(RexrReg(rde));                     /* Gv */
  int breg = RB(RexRexr(rde));                     /* Gb */
  int bits = 0, x = 0, y = 0, dst = DST_NONE, kind = -1;
  bool imm = false, write = false;

  /* ALU family: decide kind, width and operands, then emit once below */
  switch (mop) {
    case 0x00: case 0x08: case 0x20: case 0x28: case 0x30:     /* Eb op= Gb */
      kind = (Opcode(rde) & 070) >> 3; bits = 8; x = brm; y = breg; dst = brm; break;
    case 0x01: case 0x09: case 0x21: case 0x29: case 0x31:     /* Ev op= Gv */
      kind = (Opcode(rde) & 070) >> 3; bits = wb; x = erm; y = ereg; dst = erm; break;
    case 0x02: case 0x0A: case 0x22: case 0x2A: case 0x32:     /* Gb op= Eb */
      kind = (Opcode(rde) & 070) >> 3; bits = 8; x = breg; y = brm; dst = breg; break;
    case 0x03: case 0x0B: case 0x23: case 0x2B: case 0x33:     /* Gv op= Ev */
      kind = (Opcode(rde) & 070) >> 3; bits = wb; x = ereg; y = erm; dst = ereg; break;
    case 0x38: kind = K_CMP; bits = 8; x = brm; y = breg; break;
    case 0x39: kind = K_CMP; bits = wb; x = erm; y = ereg; break;
    case 0x3A: kind = K_CMP; bits = 8; x = breg; y = brm; break;
    case 0x3B: kind = K_CMP; bits = wb; x = ereg; y = erm; break;
    case 0x84: kind = K_TEST; bits = 8; x = brm; y = breg; break;
    case 0x85: kind = K_TEST; bits = wb; x = erm; y = ereg; break;
    case 0x80: case 0x81: case 0x83:                           /* op E, imm */
      kind = ModrmReg(rde);
      if (kind == 2 || kind == 3) return false;
      bits = mop == 0x80 ? 8 : wb; x = mop == 0x80 ? brm : erm; imm = true;
      if (kind != K_CMP) dst = x;
      break;
    case 0x04: case 0x0C: case 0x24: case 0x2C: case 0x34:     /* op al, imm */
      kind = (Opcode(rde) & 070) >> 3; bits = 8; x = RB(0); imm = true; dst = x; break;
    case 0x05: case 0x0D: case 0x25: case 0x2D: case 0x35:     /* op eax, imm */
      kind = (Opcode(rde) & 070) >> 3; bits = wb; x = RW(0); imm = true; dst = x; break;
    case 0x3C: kind = K_CMP; bits = 8; x = RB(0); imm = true; break;
    case 0x3D: kind = K_CMP; bits = wb; x = RW(0); imm = true; break;
    case 0xA8: kind = K_TEST; bits = 8; x = RB(0); imm = true; break;
    case 0xA9: kind = K_TEST; bits = wb; x = RW(0); imm = true; break;
    case 0xFE: case 0xFF:                                      /* inc/dec E */
      if (ModrmReg(rde) > 1) break;
      kind = ModrmReg(rde) ? K_DEC : K_INC;
      bits = mop == 0xFE ? 8 : wb; x = mop == 0xFE ? brm : erm; dst = x;
      break;
  }
  if (kind >= 0) {
    if (kind == 2 || kind == 3) return false;                  /* adc/sbb */
    write = dst == MEM;
    if (x == MEM || y == MEM) {
      if (!memok) return false;
      MemBegin(w, n, o, pcnext, bits / 8, write, true);
        LoadMem(w, n, bits, x == MEM ? LX : LY);
        EmitAlu(w, n, kind, bits, x == MEM ? SRC_PRE : x,
                imm ? SRC_IMM : y == MEM ? SRC_PRE : y, o->uimm0,
                dst == MEM ? DST_MEM : dst);
      MemEnd(w, n, o, pcnext);
      *setsip = true;
    } else {
      EmitAlu(w, n, kind, bits, x, imm ? SRC_IMM : y, o->uimm0, dst);
    }
    return true;
  }

  switch (mop) {
    case 0x88: case 0x89:                                      /* mov E, G */
    case 0x8A: case 0x8B: {                                    /* mov G, E */
      bits = mop & 1 ? wb : 8;
      int e = mop & 1 ? erm : brm, g = mop & 1 ? ereg : breg;
      bool toe = mop == 0x88 || mop == 0x89;
      if (e == MEM && !memok) return false;
      if (e == MEM) {
        MemBegin(w, n, o, pcnext, bits / 8, toe, true);
          if (toe) { LoadReg(w, n, g, bits); Set(w, n, LZ); StoreMem(w, n, bits, LZ); }
          else { LoadMem(w, n, bits, LZ); StoreRegFrom(w, n, g, LZ, bits); }
        MemEnd(w, n, o, pcnext);
        *setsip = true;
      } else {
        LoadReg(w, n, toe ? g : e, bits); Set(w, n, LZ);
        StoreRegFrom(w, n, toe ? e : g, LZ, bits);
      }
      return true;
    }
    case 0xC6: case 0xC7: {                                    /* mov E, imm */
      if (ModrmReg(rde)) return false;
      bits = mop == 0xC6 ? 8 : wb;
      int e = mop == 0xC6 ? brm : erm;
      if (e == MEM && !memok) return false;
      K64(w, n, (i64)(o->uimm0 & Mask(bits))); Set(w, n, LZ);
      if (e == MEM) {
        MemBegin(w, n, o, pcnext, bits / 8, true, true);
          StoreMem(w, n, bits, LZ);
        MemEnd(w, n, o, pcnext);
        *setsip = true;
      } else {
        StoreRegFrom(w, n, e, LZ, bits);
      }
      return true;
    }
    case 0xB0: case 0xB1: case 0xB2: case 0xB3:                /* mov r8, imm */
    case 0xB4: case 0xB5: case 0xB6: case 0xB7:
      K64(w, n, (i64)(o->uimm0 & 0xff)); Set(w, n, LZ);
      StoreRegFrom(w, n, RB(RexRexbSrm(rde)), LZ, 8);
      return true;
    case 0xB8: case 0xB9: case 0xBA: case 0xBB:                /* mov r, imm */
    case 0xBC: case 0xBD: case 0xBE: case 0xBF:
      K64(w, n, (i64)(o->uimm0 & Mask(wb))); Set(w, n, LZ);
      StoreRegFrom(w, n, RW(RexbSrm(rde)), LZ, wb);
      return true;
    case 0x1B6: case 0x1B7: case 0x1BE: case 0x1BF:            /* movzx / movsx */
    case 0x63: {                                               /* movsxd */
      int sb = mop == 0x63 ? 32 : (mop & 1) ? 16 : 8;
      bool sx = mop == 0x1BE || mop == 0x1BF || (mop == 0x63 && Rexw(rde));
      int src = mop == 0x63 || (mop & 1) ? erm : brm;
      if (mop == 0x63 && !Rexw(rde)) sx = false;               /* plain 32-bit move */
      if (src == MEM && !memok) return false;
      if (src == MEM) {
        MemBegin(w, n, o, pcnext, sb / 8, false, true);
          LoadMem(w, n, sb, LZ);
      } else {
        LoadReg(w, n, src, sb); Set(w, n, LZ);
      }
      if (sx) {
        Get(w, n, LZ);
        Op(w, n, sb == 8 ? I64EXT8S : sb == 16 ? I64EXT16S : I64EXT32S);
        if (wb < 64) { K64(w, n, (i64)Mask(wb)); Op(w, n, I64AND); }
        Set(w, n, LZ);
      }
      StoreRegFrom(w, n, ereg, LZ, wb);
      if (src == MEM) { MemEnd(w, n, o, pcnext); *setsip = true; }
      return true;
    }
    case 0x8D: {                                               /* lea Gv, M */
      int ea = Eamode(rde);
      if (regf || wb == 16 || (ea != XED_MODE_LONG && ea != XED_MODE_LEGACY)) return false;
      if (!SibExists(rde)) {
        if (IsRipRelative(rde)) {
          K64(w, n, (i64)(pcnext + (u64)o->disp));
        } else {
          K64(w, n, o->disp);
          LoadReg(w, n, RW(RexbRm(rde)), 64); Op(w, n, I64ADD);
        }
      } else {
        K64(w, n, o->disp);
        if (SibHasBase(rde)) { LoadReg(w, n, RW(RexbBase(rde)), 64); Op(w, n, I64ADD); }
        if (SibHasIndex(rde)) {
          LoadReg(w, n, RW(Rexx(rde) << 3 | SibIndex(rde)), 64);
          K64(w, n, SibScale(rde)); Op(w, n, I64SHL); Op(w, n, I64ADD);
        }
      }
      if (ea == XED_MODE_LEGACY || wb == 32) { K64(w, n, 0xffffffff); Op(w, n, I64AND); }
      Set(w, n, LZ);
      StoreRegFrom(w, n, ereg, LZ, wb);
      return true;
    }
    case 0x50: case 0x51: case 0x52: case 0x53:                /* push r64 */
    case 0x54: case 0x55: case 0x56: case 0x57:
      if (Osz(rde)) return false;
      LoadReg(w, n, RW(RexbSrm(rde)), 64); Set(w, n, LZ);      /* value first */
      LoadReg(w, n, RW(4), 64); K64(w, n, 8); Op(w, n, I64SUB); Set(w, n, LA);
      MemBegin(w, n, o, pcnext, 8, true, false);
        StoreRegFrom(w, n, RW(4), LA, 64);
        StoreMem(w, n, 64, LZ);
      MemEnd(w, n, o, pcnext);
      *setsip = true;
      return true;
    case 0x58: case 0x59: case 0x5A: case 0x5B:                /* pop r64 */
    case 0x5C: case 0x5D: case 0x5E: case 0x5F:
      if (Osz(rde)) return false;
      LoadReg(w, n, RW(4), 64); Set(w, n, LA);
      MemBegin(w, n, o, pcnext, 8, false, false);
        LoadMem(w, n, 64, LZ);
        Get(w, n, LA); K64(w, n, 8); Op(w, n, I64ADD); Set(w, n, LE);
        StoreRegFrom(w, n, RW(4), LE, 64);
        StoreRegFrom(w, n, RW(RexbSrm(rde)), LZ, 64);
      MemEnd(w, n, o, pcnext);
      *setsip = true;
      return true;
    case 0xE8:                                                 /* call rel */
      if (Osz(rde)) return false;
      K64(w, n, (i64)pcnext); Set(w, n, LZ);
      K64(w, n, (i64)(pcnext + (u64)o->disp)); Set(w, n, LY);
      PushFast(w, n, o, pcnext, LZ, LY);
      *setsip = true;
      return true;
    case 0xC3:                                                 /* ret */
      if (Osz(rde)) return false;
      LoadReg(w, n, RW(4), 64); Set(w, n, LA);
      MemBegin(w, n, o, pcnext, 8, false, false);
        LoadMem(w, n, 64, LZ);
        Get(w, n, LA); K64(w, n, 8); Op(w, n, I64ADD); Set(w, n, LE);
        StoreRegFrom(w, n, RW(4), LE, 64);
        SetIpFrom(w, n, LZ);
      MemEnd(w, n, o, pcnext);
      *setsip = true;
      return true;
    case 0xFF: {                       /* call / jmp / push Ev (inc/dec above) */
      int r = ModrmReg(rde);
      if ((r != 2 && r != 4 && r != 6) || Osz(rde)) return false;
      if (erm == MEM && !memok) return false;
      /* LX = the 64-bit Ev operand (read before rsp moves) */
      if (erm != MEM) {
        LoadReg(w, n, erm, 64); Set(w, n, LX);
        if (r == 4) { SetIpFrom(w, n, LX); *setsip = true; return true; }
      } else {
        MemBegin(w, n, o, pcnext, 8, false, true);
          LoadMem(w, n, 64, LX);
          if (r == 4) SetIpFrom(w, n, LX);
      }
      if (r == 2) {                                            /* call */
        K64(w, n, (i64)pcnext); Set(w, n, LZ);
        PushFast(w, n, o, pcnext, LZ, LX);
      } else if (r == 6) {                                     /* push */
        PushFast(w, n, o, pcnext, LX, -1);
      }
      if (erm == MEM) MemEnd(w, n, o, pcnext);
      *setsip = true;
      return true;
    }
    case 0xEB: case 0xE9:                                      /* jmp rel */
      Get(w, n, 0); K64(w, n, (i64)(pcnext + (u64)o->disp));
      Mem(w, n, I64ST, 3, offsetof(struct Machine, ip));
      *setsip = true;
      return true;
    default:
      if (((mop >= 0x70 && mop <= 0x7F) || (mop >= 0x180 && mop <= 0x18F)) &&
          (mop & 15) != 0xA && (mop & 15) != 0xB) {
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

/* the block's tail: call a linked successor, or leave our cells for the
   dispatcher to link (see the header comment) */
static void EmitChain(struct Wj *w, size_t *n) {
  const u32 X = (u32)(uintptr_t)w->curexits;
  const u32 DEPTH = (u32)(uintptr_t)&w->depth;
  const u32 LAST = (u32)(uintptr_t)&w->lastexit;
  const u32 EPOCH = (u32)(uintptr_t)&g_wj_chain;
  Get(w, n, 0); Mem(w, n, I64LD, 3, offsetof(struct Machine, ip)); Set(w, n, LA);
  for (int k = 0; k < 2; k++) {
    K32(w, n, (i32)X); Mem(w, n, I64LD, 3, offsetof(struct WjExits, pc) + 8 * k);
    Get(w, n, LA); Op(w, n, I64EQ);
    K32(w, n, (i32)X); Mem(w, n, I32LD, 2, offsetof(struct WjExits, epoch) + 4 * k);
    K32(w, n, (i32)EPOCH); Mem(w, n, I32LD, 2, 0); Op(w, n, I32EQ); Op(w, n, I32AND);
    Get(w, n, 0); Mem(w, n, I32LD8U, 0, offsetof(struct Machine, attention));
    Op(w, n, EQZ32); Op(w, n, I32AND);
    K32(w, n, (i32)DEPTH); Mem(w, n, I32LD, 2, 0); K32(w, n, WJ_MAXDEPTH); Op(w, n, I32LTU);
    Op(w, n, I32AND);
    B(w, n, IF); B(w, n, 0x40);
      K32(w, n, (i32)DEPTH); K32(w, n, (i32)DEPTH); Mem(w, n, I32LD, 2, 0);
      K32(w, n, 1); Op(w, n, I32ADD); Mem(w, n, I32ST, 2, 0);
      Get(w, n, 0); K64(w, n, 0); K64(w, n, 0); K64(w, n, 0);
      K32(w, n, (i32)X); Mem(w, n, I32LD, 2, offsetof(struct WjExits, slot) + 4 * k);
      B(w, n, CALLI); U(w, n, 0); U(w, n, 0);
      K32(w, n, (i32)DEPTH); K32(w, n, (i32)DEPTH); Mem(w, n, I32LD, 2, 0);
      K32(w, n, 1); Op(w, n, I32SUB); Mem(w, n, I32ST, 2, 0);
      Op(w, n, RET);
    B(w, n, END);
  }
  K32(w, n, (i32)LAST); K32(w, n, (i32)X); Mem(w, n, I32ST, 2, 0);
}

/* the op's handler, as JitlessDispatch would run it, then
   `if (m->ip != pc) { m->oplen = 0; return; }` */
static void EmitHandler(struct Wj *w, size_t *n, struct WjOp *o, u64 pc, bool prologue) {
  const u32 OIP = offsetof(struct Machine, ip);
  const u32 OLEN = offsetof(struct Machine, oplen);
  const u32 OSTASH = offsetof(struct Machine, stashaddr);
  const u32 COMMIT = (u32)(uintptr_t)CommitStash;
  if (prologue) {               /* m->ip = pc; m->oplen = len */
    Get(w, n, 0); K64(w, n, (i64)pc); Mem(w, n, I64ST, 3, OIP);
    Get(w, n, 0); K32(w, n, o->len); Mem(w, n, I32ST8, 0, OLEN);
  }
  /* op(m, rde, disp, uimm0) */
  Get(w, n, 0);
  K64(w, n, (i64)o->rde); K64(w, n, o->disp); K64(w, n, (i64)o->uimm0);
  K32(w, n, (i32)o->fn);
  B(w, n, CALLI); U(w, n, 0); U(w, n, 0);
  /* if (m->stashaddr) CommitStash(m) */
  Get(w, n, 0); Mem(w, n, I64LD, 3, OSTASH); Op(w, n, I64EQZ); Op(w, n, EQZ32);
  B(w, n, IF); B(w, n, 0x40);
    Get(w, n, 0); K32(w, n, (i32)COMMIT); B(w, n, CALLI); U(w, n, 1); U(w, n, 0);
  B(w, n, END);
  Get(w, n, 0); Mem(w, n, I64LD, 3, OIP); K64(w, n, (i64)pc); Op(w, n, I64NE);
  B(w, n, IF); B(w, n, 0x40);
    Get(w, n, 0); K32(w, n, 0); Mem(w, n, I32ST8, 0, OLEN);
    Op(w, n, RET);
  B(w, n, END);
}

static void EmitBody(struct Wj *w, size_t *n) {
  const u32 OIP = offsetof(struct Machine, ip);
  const u32 OLEN = offsetof(struct Machine, oplen);
  const u32 OATT = offsetof(struct Machine, attention);
  u64 pc = w->start;
  bool ipset = true;      /* m->ip holds the right value at this point */
  OREG = offsetof(struct Machine, weg);
  OFLAGS = offsetof(struct Machine, flags);
  OTLB = offsetof(struct Machine, tlb);
  OINV = offsetof(struct Machine, invalidated);
  for (int k = 0; k < 8; k++)
    OSEGB[k] = offsetof(struct Machine, seg) + k * sizeof(struct DescriptorCache) +
               offsetof(struct DescriptorCache, base);
  HOSTPAGES = (u32)(uintptr_t)&g_hostpages.p;
  /* locals: 5 x i64 (LX LY LZ LA LE), 4 x i32 (LF LT LP LH) */
  B(w, n, 2); B(w, n, 5); B(w, n, 0x7e); B(w, n, 4); B(w, n, 0x7f);
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
    EmitHandler(w, n, o, pc, true);
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
  EmitChain(w, n);
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
  if (!(w->curexits = calloc(1, sizeof *w->curexits))) { e->state = 2; return; }
  size_t len = EmitModule(w);
  long slot = len ? syscall(NR_LOT_WASM_LOAD, w->code, len) : -1;
  if (slot <= 0) {
    if (errno == ENOSYS || errno == ENOSPC) g_wj_mode = 0;   /* runtime can't */
    free(w->curexits);
    w->curexits = 0;
    e->state = 2;
    s_failed++;
    return;
  }
  w->curexits = 0;                 /* owned by the translation from now on */
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
  struct WjExits *x = w->lastexit;
  w->lastexit = 0;
  w->depth = 0;                    /* a fault's longjmp skips the decrements */
  if (!w->rec && w->atstart) {
    struct WjEntry *e = WjFind(w, pc);
    if (e) {
      if (e->state == 1) {
        if (atomic_load_explicit(&e->pg->gen, memory_order_acquire) == e->gen) {
          if (x) {                 /* link the block we came from to this one */
            int k = x->pc[0] == pc ? 0 : x->pc[1] == pc ? 1 :
                    !x->slot[0] ? 0 : !x->slot[1] ? 1 : (int)(x->next ^= 1);
            x->pc[k] = pc;
            x->slot[k] = e->slot;
            x->epoch[k] = atomic_load_explicit(&g_wj_chain, memory_order_acquire);
            s_links++;
          }
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

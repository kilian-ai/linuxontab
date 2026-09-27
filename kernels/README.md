# Kernel source for `shell/linux-dist/vmlinux.wasm`

LinuxOnTab 2.0 boots a real Linux kernel compiled to WebAssembly. The kernel
is GPL-2.0 (`GPL-2.0 WITH Linux-syscall-note`), so the exact source of every
shipped binary is public:

- **Repository:** https://github.com/kilian-ai/linux — a fork of
  [tombl/linux](https://github.com/tombl/linux) (Thomas Stokes' `arch/wasm`
  port; all credit for the port itself goes there)
- **Branches:** `wasm-linuxontab-7.1` (Linux 7.1 — what the site boots,
  `shell/linux-dist-7.1/vmlinux.wasm`) and `wasm-linuxontab` (Linux 6.1, the
  previous runtime, `shell/linux-dist/vmlinux.wasm`)
- **Commit behind each shipped binary:** [`vmlinux-7.1.source`](vmlinux-7.1.source)
  and [`vmlinux.source`](vmlinux.source).
  The same text is embedded in the `.wasm` as a custom section, so a binary
  can always be traced back to its source:

  ```js
  new TextDecoder().decode(
    WebAssembly.Module.customSections(module, '.linuxontab.source')[0])
  ```

`kernels/linux/` is deliberately **not** tracked here (`.gitignore`) — it is a
full kernel tree. Clone it next to this file:

```bash
git clone -b wasm-linuxontab-7.1 https://github.com/kilian-ai/linux kernels/linux-7.1
git -C kernels/linux-7.1 remote rename origin linuxontab   # the deploy script expects this name
# the 6.1 tree, only if you need to rebuild the previous runtime:
git clone -b wasm-linuxontab https://github.com/kilian-ai/linux kernels/linux
```

## Build

Needs LLVM **19** (`brew install llvm@19` — plain `llvm` is too new: `wasm-ld`
isn't found and `syncconfig` wipes `autoconf.h`), `node`, and for 7.1 GNU Make
**4+** (`brew install make` → `gmake`; Xcode's make is 3.81) plus `wabt`:

```bash
export PATH="/opt/homebrew/opt/llvm@19/bin:/opt/homebrew/opt/make/bin:$PATH"
gmake -C kernels/linux-7.1 linuxontab_defconfig
gmake -C kernels/linux-7.1 vmlinux.wasm -j8            # 6.1: make -C kernels/linux tools/wasm/vmlinux.wasm
```

That produces `kernels/linux/tools/wasm/vmlinux.wasm` with a 1 MB initramfs
baked into a `.linux.initramfs` custom section. The shipped file replaces it
with a 512-byte stub (the page fetches `initramfs.cpio` separately).

## Ship it

```bash
kernels/deploy-vmlinux.sh            # 7.1 (default); `kernels/deploy-vmlinux.sh 6.1` for the old tree
git add shell/linux-dist-7.1/vmlinux.wasm kernels/vmlinux-7.1.source && git commit
```

The script builds, swaps the initramfs stub, embeds the source pointer and
writes `vmlinux.source`. It **refuses** if the kernel tree has uncommitted
changes or if `HEAD` isn't on the public fork branch — the binary must always
correspond to a commit anyone can fetch. `LOT_ALLOW_DIRTY=1` overrides for a
local-only experiment (never for a deploy).

The 7.1 page runtime is built from `shell/linux-dist-7.1/src/` (tombl/distro's
`@lowland/kernel` plus LinuxOnTab changes) by `shell/linux-dist-7.1/build.sh`.
The 6.1 runtime under `shell/linux-dist/dist/` came from `tools/wasm/src/*.ts`
in the 6.1 tree.

## macOS note

The kernel tree contains file pairs that differ only by case
(`xt_CONNMARK.h` / `xt_connmark.h`, `net/netfilter/xt_DSCP.c` / `xt_dscp.c`,
one litmus test). On a case-insensitive filesystem `git status` shows them as
modified forever; they are not edits and are not part of the wasm build. The
deploy script ignores them. Don't commit them.

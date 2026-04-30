# v86 Standalone — self-contained Linux terminal in the browser

Zero-server, zero-framework, runs from `file://`. Uses the [v86](https://github.com/copy/v86)
x86 emulator (official upstream) with Buildroot/Linux live ISOs.

## Run

Double-click `standalone-v86.html`, or:

```
open standalone-v86.html
```

URL params:
- `?iso=linux4.iso` &mdash; select image
- `?autoboot=1` &mdash; start emulator immediately
- `?restore=1` &mdash; restore saved snapshot on autoboot

## Files

| File | Size | Origin | Purpose |
|------|------|--------|---------|
| `libv86.js` | 0.3 MB | copy.sh/v86 | v86 emulator JS |
| `v86.wasm` | 1.4 MB | copy.sh/v86 | v86 CPU WASM core |
| `seabios.bin` | 128 KB | copy.sh/v86 | BIOS |
| `vgabios.bin` | 36 KB | copy.sh/v86 | VGA BIOS |
| `linux.iso` | 5.4 MB | copy.sh/v86 | Kernel 2.6.34 + Buildroot + Lua |
| `linux3.iso` | 8.2 MB | copy.sh/v86 | Kernel 3.x + Buildroot |
| `linux4.iso` | 7.4 MB | copy.sh/v86 | Kernel 4.16.13 + Buildroot + busybox |
| `standalone-v86.html` | 7 KB | this repo | Terminal UI + snapshot mgmt |
| `xterm.js` | 0.3 MB | @xterm/xterm@5.5.0 | Terminal renderer (VT/ANSI/xterm) |
| `xterm.css` | 5 KB | @xterm/xterm@5.5.0 | Terminal styles |
| `xterm-addon-fit.js` | 1.5 KB | @xterm/addon-fit@0.10.0 | Auto-fit to container |

Total shipped: ~24 MB.

## Features

- **Boot/reset** any of 3 Linux ISOs
- **Save/restore snapshot** via `emulator.save_state()` / `initial_state` → IndexedDB (`v86-snapshots/snap:<iso>`)
- **Auto-save checkbox**: debounced snapshot ~3s after any serial activity — functionally
  a VFS-level persistence layer. Each save is ~54 MB in ~100 ms, rate-limited to once/5s.
  Toggle state persists via `localStorage['v86.autosave']`.
- **Serial0 I/O**: xterm.js renders the raw VT stream directly (full 256-color
  support, cursor styles, scrollback, selection); input goes through xterm.js's
  `onData` which already encodes arrows, Ctrl-keys, etc.
- **Auto-resize + stty propagation**: FitAddon sizes xterm to the container;
  on every resize the new `stty cols N rows M` is sent to the guest so `ls`,
  `less`, etc. wrap correctly.
- **Auto-boot/restore** via query string for deep-linking

## Known good

Tested on macOS Chrome + Playwright Chromium (file://). Confirmed:
- linux.iso → busybox shell with Lua (kernel 2.6.34)
- linux4.iso → busybox shell (kernel 4.16.13)
- Snapshot save: ~53 MB, < 1s to IndexedDB
- Snapshot restore: instant resume of shell with prior filesystem state

## Not included (yet)

- Host↔guest filesystem bridge (9p host_url) — would need network or manual per-file transfer
- xterm.js-grade colors/cursor (current renderer strips ANSI, just good enough for line-oriented shell)
- Network (linux4.iso has no network adapter configured)

These are straightforward to add if needed.

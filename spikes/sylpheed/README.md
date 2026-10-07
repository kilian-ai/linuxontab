# Spike: Sylpheed (GTK 2 mail client) on xtiny

Sylpheed 3.7.0 on a full GTK 2.24 stack, as a static wasm binary for the
guest's X server (xtiny). Status 2026-10-07: it runs, the account wizard works
with mouse and keyboard, and IMAPS reaches Gmail. GTK menus open only
sometimes, it isn't packaged, and it needs an unreleased runtime and xtiny.

## Build

    docker build -t lot-gtk-build spikes/sylpheed     # LibreOffice image + GLib/GTK host tools
    sh spikes/sylpheed/run.sh                         # all steps; or: run.sh glib pango ...

The steps (`build.sh`) run in the LibreOffice build container (`wasm-cc`: wasm
exceptions, native setjmp/longjmp, threads, userspace mmap). They reuse the
Xfe build's zlib/libpng/freetype/expat/fontconfig (`/work/fm/prefix`) and the
guest's X11 libraries (`/work/xprefix`):

    ffi glib(2.84.4 + pcre2) fribidi harfbuzz pixman cairo(xlib) pango atk
    gdk-pixbuf gtk(2.24.33) openssl(1.1.1w) sylpheed(3.7.0)

The output is `/work/gtk/sylroot/usr/bin/sylpheed`: about 12 MB of wasm, no asyncify, so no
fork. At runtime it needs DejaVu fonts and `/etc/fonts/fonts.conf`, which the
xfe package ships.

## What it took

- **libffi**: there is no wasm32 port outside emscripten. GObject only needs
  `ffi_call`, which `ffi/gen-dispatch.py` generates as a dispatch over the wasm
  signature. Each argument is classed as i32/i64/f32/f64; all mixes are covered
  up to 4 arguments, i32/f64 mixes for 5–6, and all-i32 up to 12. Anything else
  aborts with the signature.
- **Function pointer casts**: GTK 2 calls through mismatched types
  everywhere. One-argument class_init functions get called with two, and so
  do short signal handlers. On wasm each of these is a trapping
  `call_indirect`. Binaryen's `--fpcast-emu` (max-func-params 20) fixes it
  globally, and the 7.1 worker adapts its own JS-side table calls for modules
  exporting `__lot_fpcast` (commit 94170ebc).
- **Static X**: our libX11 has no XKB or xlibi18n. GTK is built with
  `ac_cv_func_XkbQueryExtension=no` plus one `#ifdef` 2.24.33 is missing.
  `gtk_x11_compat.c` covers XmbSetWMProperties and the fontset draws.
- Build details:
  - the X packages' `.pc` files leak the build host's link tail, so they're
    cleaned into `/work/gtk/xpc`;
  - meson needs `prefer_static`;
  - gdk-pixbuf's tools need libpng named explicitly;
  - glib's pcre2 comes from its subproject.
- **Sylpheed 3.7 sends no SNI**, so Gmail answered with its "No SNI provided"
  certificate. Patched in `build.sh` (`SSL_set_tlsext_host_name`).
- **xtiny** needed several fixes for GTK 2 (commits 9842d304, f070c47f, cc21e9f2):
  - pointer event propagation, implicit grab, Enter/LeaveNotify;
  - GC clip rectangles (GDK repaints through a double-buffer pixmap);
  - motion delivered before the press;
  - QueryPointer's child field: GDK walks it to find the window under the
    pointer, so with `None` every click after the first was lost;
  - transient dialogs stay above their parent; more properties per window.
- `test/gtkbtn.c` (`run.sh gtktest`) logs GTK's crossing, press and release
  events and button signals. Use it to debug xtiny/GTK input.

## Open

- GTK menus: a menubar click opens the menu only sometimes. GTK grabs the
  pointer while xtiny's implicit grab is active (X turns that into an active
  grab), so check xtiny's GrabPointer/UngrabPointer handling against that.
- Packaging: an apk with fonts (or `depends: xfe` for its fonts), a desktop
  entry, and an xtiny Apps entry.
- Shipping needs the worker change (94170ebc) deployed (Pages) and an xtiny
  release with cc21e9f2 + f070c47f.

# Hosted snapshots

Pre-built v86 RAM snapshots that the shell can restore instead of going
through a full ISO boot. Loads about 5–10× faster.

## Loading

```
https://linuxontab.com/shell/?snapshot=<url>
```

Accepted URL forms:
- **Relative**: `?snapshot=snapshots/alpine-base.bin.gz` (served from this dir).
- **Same-origin**: `?snapshot=https://linuxontab.com/shell/snapshots/foo.bin.gz`.
- **Any https://**: e.g. a GitHub Release asset
  `?snapshot=https://github.com/kilian-ai/linuxontab/releases/download/snap-v1/alpine-base.bin.gz`.
  (User-opted-in — same trust model as `?postboot=`.)

Files ending in `.gz` are transparently decompressed via
`DecompressionStream` before being fed to v86.

`?reset=1` always wins and forces a fresh ISO boot, even if `?snapshot=`
is set.

## Hosting on GitHub Releases (recommended)

GitHub Pages won't serve files >100 MB and Git LFS pointers don't
resolve to binaries on Pages. Releases sidestep both: 2 GB per file,
no repo bloat, served with CORS-friendly redirects.

```sh
gh release create snap-v1 \
  --title "Snapshots v1" \
  --notes "alpine-base 256 MB" \
  shell/snapshots/alpine-base.bin.gz
```

The asset is then at:
```
https://github.com/kilian-ai/linuxontab/releases/download/snap-v1/alpine-base.bin.gz
```

Use that URL with `?snapshot=…`.

## Hosting in this directory (small files only)

Files <100 MB can be committed directly. They're served at
`https://linuxontab.com/shell/snapshots/<name>`.

## Creating a snapshot (in the shell)

1. Boot fresh with a small VM:
   ```
   https://linuxontab.com/shell/?reset=1&mem=256
   ```
2. Wait for prompt, install/configure to taste.
3. Zero out free RAM so gzip can crush it (skip if you want — but
   the snapshot will be 5–10× larger):
   ```sh
   dd if=/dev/zero of=/tmp/zero bs=1M count=150 2>/dev/null
   sync; rm -f /tmp/zero; sync
   echo 3 > /proc/sys/vm/drop_caches
   ```
   (Tune `count=` so it doesn't OOM. ~75% of `free -m` available.)
4. In DevTools console:
   ```js
   await exportSnapshot({ name: 'alpine-base.bin' })
   ```
   This save_state()s + gzips + downloads `alpine-base.bin.gz`.

## Sizing

A snapshot is the full VM RAM image. A 256 MB VM produces a ~256 MB
raw blob. With zeroed free pages, gzip compresses to ~10–25 MB.

`?mem=` at boot determines the snapshot size — match the VM size to
your workload.

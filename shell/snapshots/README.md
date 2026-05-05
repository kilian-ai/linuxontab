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

## Tuning the post-restore init script

The shell runs a sequence of init "modules" after boot/restore. The
hosted-snapshot path uses a much leaner default than fresh boot, but
you can override either way:

- `?init=net,time` — exact module list (overrides defaults).
- `?init=none` — skip the init script entirely.
- `?skip=dns-seed,dns-proxy` — remove modules from the default set.

Available modules:
| name        | what it does                                  | typical cost |
|-------------|-----------------------------------------------|--------------|
| `rootfs`    | remount tmpfs `/` (with `?rootfs=<size>`)     | <1 s         |
| `9p`        | mount `/mnt/host` + install Node TUI fix + `lot` script | 1–2 s |
| `hostdirs`  | mkdir `/root/{public,following}`              | <1 s         |
| `net`       | eth0 bounce + static IP + ARP (post-restore)  | 5–8 s        |
| `dhcp`      | `udhcpc` (clean ISO boot path)                | 2–4 s        |
| `dns-seed`  | DoH-seed `/etc/hosts` for 8 hostnames         | 3–5 s        |
| `dns-proxy` | install + start `unbound` for TCP DNS         | 1–15 s       |
| `time`      | `rdate`/`ntpd` clock sync (needed for TLS)    | 1 s          |
| `tmux`      | start `lot` tmux session                      | <1 s         |
| `setup`     | apk repo + apk upgrade + base packages        | 10–30 s      |
| `clear`     | `clear` the screen                            | -            |

Defaults:
- `?snapshot=<url>`: `net,time,tmux` (rest is baked in).
- IDB restore (no `?snapshot=`): `rootfs,9p,hostdirs,net,dns-seed,dns-proxy,time,tmux`.
- Fresh ISO boot: `rootfs,9p,hostdirs,dhcp,dns-seed,dns-proxy,time,clear,setup`.

Example: skip the slow DNS path entirely on a hosted-snapshot boot
(if you know the snapshot already has unbound running):
```
?snapshot=…&skip=dns-seed,dns-proxy
```

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

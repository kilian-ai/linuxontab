# Hosted snapshots

Drop v86 snapshot binaries here and load them with the `?snapshot=` URL
parameter for a much faster cold start (skips ISO boot + apk update +
package install).

## Creating a snapshot

1. Boot the shell normally and get the guest into the state you want
   (packages installed, configs written, etc.).
2. Use the **save** button in the top toolbar to write a snapshot to
   IndexedDB.
3. Open DevTools → Application → IndexedDB → `v86-states` → find your
   snapshot key, right-click the value → "Store value as global
   variable" (`temp1`).
4. In the console:
   ```js
   const blob = new Blob([temp1]);
   const a = document.createElement('a');
   a.href = URL.createObjectURL(blob);
   a.download = 'alpine-base.bin';
   a.click();
   ```
5. Move the downloaded file into this directory and commit. It will be
   served at `https://linuxontab.com/shell/snapshots/<name>.bin`.

## Loading

```
https://linuxontab.com/shell/?snapshot=snapshots/alpine-base.bin
```

Same-origin only — cross-origin URLs are rejected. The snapshot must
match the ISO architecture (default `alpine.iso`); pair with `&iso=`
if needed.

`?reset=1` always wins and forces a fresh ISO boot, even if `?snapshot=`
is set.

## Sizing

Snapshots are uncompressed RAM dumps so they're large (a 2 GB Alpine VM
produces a ~2 GB snapshot). Use [Git LFS](../.gitattributes) for
anything over a few MB. GitHub Pages serves LFS-tracked files normally,
but they count against your LFS bandwidth quota.

For tiny base snapshots (e.g. busybox, 128 MB VM) the file may be small
enough to commit directly without LFS.

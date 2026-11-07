#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
OUT="$ROOT/dist"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$ROOT/index.html" "$ROOT/robots.txt" "$ROOT/sitemap.xml" "$ROOT/og.png" "$OUT/"
if [[ -f "$ROOT/.nojekyll" ]]; then cp "$ROOT/.nojekyll" "$OUT/"; fi
for dir in shell viewer local changelog; do
  if [[ -d "$ROOT/$dir" ]]; then cp -a "$ROOT/$dir" "$OUT/$dir"; fi
done
rm -f "$OUT/shell/alpine.iso"
mkdir -p "$OUT/packages"
cat > "$OUT/packages/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LinuxOnTab packages</title></head>
<body style="font:16px system-ui;max-width:720px;margin:4rem auto;padding:0 1rem;background:#0b0d10;color:#e8edf2">
<h1>LinuxOnTab package archive</h1>
<p>Package files are served on demand after sign-in.</p>
<p><a style="color:#8dc5ff" href="/">Return to LinuxOnTab</a></p>
</body>
</html>
HTML
oversized="$(find "$OUT" -type f -size +25M -print -quit)"
if [[ -n "$oversized" ]]; then
  echo "ERROR: Pages asset exceeds 25 MiB: $oversized" >&2
  exit 1
fi
echo "Cloudflare Pages output ready: $OUT"
du -sh "$OUT"

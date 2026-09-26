#!/usr/bin/env sh
# Bundle the 7.1 page runtime: tombl/distro's @lowland/kernel (MIT) +
# LinuxOnTab's additions, into dist/{index,worker}.js. Needs node.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ESB="npx -y esbuild@0.24.2"
COMMON="--bundle --format=esm --platform=browser --target=es2022 --alias:@lowland/bytes=$HERE/src/bytes/index.ts"
$ESB src/kernel/index.ts  $COMMON --outfile=dist/index.js
$ESB src/kernel/worker.ts $COMMON --outfile=dist/worker.js
echo "built dist/index.js dist/worker.js"

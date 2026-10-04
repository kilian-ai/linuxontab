// /linux-dist/x86-chromium.ext4: a read-only extra disk (wasm.html ?xdisk=), streamed
// from R2 parts — see ../../lib/r2image.js; upload with
//   IMAGE=x86-chromium.ext4 [GZIP=1] ./upload-rootfs.sh
import { r2Image } from "../../lib/r2image.js";

export const { onRequestGet, onRequestHead } = r2Image("x86-chromium.ext4");

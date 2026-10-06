// /linux-dist/libreoffice.ext4: the read-only LibreOffice disk (wasm.html
// ?xdisk=, mounted at /opt/lo), streamed from R2 parts — see
// ../../lib/r2image.js; build with spikes/libreoffice/make-image.sh, upload with
//   IMAGE=libreoffice.ext4 GZIP=1 ./upload-rootfs.sh
import { r2Image } from "../../lib/r2image.js";

export const { onRequestGet, onRequestHead } = r2Image("libreoffice.ext4");

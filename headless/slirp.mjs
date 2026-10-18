// Loads WispSlirp — the guest's user-mode TCP/IP stack — out of
// shell/wasm.html, so the headless runner runs the exact code the page runs
// (its TCP flow control, DNS interception and HTTP gateway at 192.168.86.1
// carry months of fixes). It is a self-contained class in the page's module
// script; the browser globals it touches are supplied here.
//
// TODO: move WispSlirp into its own module imported by both wasm.html and the
// runner. Slicing it out of the page keeps the live page untouched for now.
import { readFileSync } from "node:fs";

export function loadWispSlirp({ wasmHtml, search = "", openWispTransport, console: log }) {
  const lines = readFileSync(wasmHtml, "utf8").split("\n");
  const start = lines.findIndex((l) => /^class WispSlirp \{/.test(l));
  if (start < 0) throw new Error(`class WispSlirp not found in ${wasmHtml}`);
  let end = start + 1;
  while (end < lines.length && !/^\}/.test(lines[end])) end++;
  if (end >= lines.length) throw new Error("end of class WispSlirp not found");
  const source = lines.slice(start, end + 1).join("\n");

  // The page's origin decides where the HTTP gateway and package drop fetch
  // from: anything but localhost means https://linuxontab.com.
  const location = { search, hostname: "headless", origin: "https://linuxontab.com", href: "https://linuxontab.com/" };
  // `window` carries the page's debug switches (__netdebug, __slirpdbg, ...)
  // and a few hooks; everything else falls through to Node's globals.
  const window = { location, __lotConsoleKick: () => {} };
  const unavailable = (what) => () => { throw new Error(`${what} is not available in the headless runner`); };

  const factory = new Function(
    "window", "location", "openWispTransport", "evalInPageV8", "guestAgentCall", "lotTls", "console",
    `${source}\nreturn WispSlirp;`,
  );
  const WispSlirp = factory(
    window, location, openWispTransport,
    unavailable("evalInPageV8 (/_v8/eval)"), unavailable("guestAgentCall"), unavailable("page TLS"),
    log,
  );
  return { WispSlirp, window };
}

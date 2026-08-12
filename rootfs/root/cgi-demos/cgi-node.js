var o = require("os");
var css = "body{margin:0;font-family:system-ui,sans-serif;background:#0d1117;color:#e6edf3}"
  + ".hd{background:#0d1b2e;padding:16px 24px;border-bottom:1px solid #30363d}"
  + ".hd h2{margin:0;color:#58a6ff;font-size:1.2rem}"
  + ".hd p{margin:4px 0 0;color:#8b949e;font-size:.8rem}"
  + ".g{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;padding:16px 24px}"
  + ".c{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:12px}"
  + ".l{font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:#8b949e;margin-bottom:4px}"
  + ".v{font-family:monospace;font-weight:700;color:#e6edf3;font-size:1rem}"
  + ".badge{display:inline-block;background:#033a16;color:#3fb950;border:1px solid #238636;"
  + "border-radius:4px;padding:1px 8px;font-size:11px;margin-top:6px}";

var h = "<!doctype html><html><head><meta charset=utf-8><title>Node.js CGI</title>"
  + "<style>" + css + "</style></head><body>";
h += "<div class=hd><h2>Node.js CGI</h2>"
  + "<p>Linux 6.1 wasm32 on " + o.hostname() + "</p></div>";
h += "<div class=g>";
h += "<div class=c><div class=l>Runtime</div><div class=v>" + process.version + "</div>"
  + "<div class=badge>wasm32</div></div>";
h += "<div class=c><div class=l>Platform</div><div class=v>"
  + o.platform() + "/" + o.arch() + "</div></div>";
h += "<div class=c><div class=l>Uptime</div><div class=v>"
  + Math.floor(o.uptime()) + "s</div></div>";
h += "<div class=c><div class=l>RAM free/total</div><div class=v>"
  + Math.round(o.freemem() / 1048576) + "/"
  + Math.round(o.totalmem() / 1048576) + " MB</div></div>";
h += "<div class=c><div class=l>PID</div><div class=v>" + process.pid + "</div></div>";
h += "</div></body></html>";

process.stdout.write("Status: 200 OK\nContent-Type: text/html; charset=utf-8\n\n" + h);

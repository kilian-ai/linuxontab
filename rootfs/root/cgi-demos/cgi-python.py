import os, sys, platform

u = os.uname()
css = ("body{margin:0;font-family:system-ui,sans-serif;background:#0d1117;color:#e6edf3}"
    + ".hd{background:#1a0a2e;padding:16px 24px;border-bottom:1px solid #30363d}"
    + ".hd h2{margin:0;color:#a78bfa;font-size:1.2rem}"
    + ".hd p{margin:4px 0 0;color:#8b949e;font-size:.8rem}"
    + ".g{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;padding:16px 24px}"
    + ".c{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:12px}"
    + ".l{font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:#8b949e;margin-bottom:4px}"
    + ".v{font-family:monospace;font-weight:700;color:#e6edf3;font-size:1rem}"
    + ".badge{display:inline-block;background:#2a0944;color:#a78bfa;border:1px solid #7c3aed;"
    + "border-radius:4px;padding:1px 8px;font-size:11px;margin-top:6px}")

h = "<!doctype html><html><head><meta charset=utf-8><title>Python3 CGI</title>"
h += "<style>" + css + "</style></head><body>"
h += "<div class=hd><h2>Python3 CGI</h2>"
h += "<p>Linux 6.1 wasm32 on " + u.nodename + "</p></div>"
h += "<div class=g>"
h += ("<div class=c><div class=l>Runtime</div><div class=v>Python "
    + sys.version.split()[0] + "</div><div class=badge>wasm32</div></div>")
h += ("<div class=c><div class=l>Platform</div><div class=v>"
    + platform.system() + "/" + u.machine + "</div></div>")
h += "<div class=c><div class=l>Kernel</div><div class=v>" + u.release + "</div></div>"
h += "<div class=c><div class=l>PID</div><div class=v>" + str(os.getpid()) + "</div></div>"
h += "</div></body></html>"

print("Status: 200 OK\nContent-Type: text/html; charset=utf-8\n\n" + h)

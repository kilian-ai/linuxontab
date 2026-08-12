#!/bin/sh
# Shell CGI demo — builtins only, no forks
echo "Status: 200 OK"
echo "Content-Type: text/html; charset=utf-8"
echo
printf '<!doctype html><html><head><meta charset=utf-8><title>Shell CGI</title>'
printf '<style>'
printf 'body{margin:0;font-family:system-ui,sans-serif;background:#0d1117;color:#e6edf3}'
printf '.hd{background:#0c2a1a;padding:16px 24px;border-bottom:1px solid #30363d}'
printf '.hd h2{margin:0;color:#4ade80;font-size:1.2rem}'
printf '.hd p{margin:4px 0 0;color:#8b949e;font-size:.8rem}'
printf '.g{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;padding:16px 24px}'
printf '.c{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:12px}'
printf '.l{font-size:10px;text-transform:uppercase;letter-spacing:.08em;color:#8b949e;margin-bottom:4px}'
printf '.v{font-family:monospace;font-weight:700;color:#e6edf3;font-size:1rem}'
printf '.badge{display:inline-block;background:#033a0c;color:#4ade80;border:1px solid #22c55e;'
printf 'border-radius:4px;padding:1px 8px;font-size:11px;margin-top:6px}'
printf '</style></head><body>'
printf '<div class=hd><h2>Shell CGI</h2>'
printf '<p>Linux 6.1 wasm32 — builtins only, zero forks</p></div>'
printf '<div class=g>'
printf '<div class=c><div class=l>Shell</div><div class=v>/bin/sh</div>'
printf '<div class=badge>busybox ash</div></div>'
printf '<div class=c><div class=l>PID</div><div class=v>%s</div></div>\n' "$$"
printf '</div></body></html>\n'

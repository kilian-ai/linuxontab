# LinuxOnTab Web UI — Guest Agent

You are running **inside the Alpine Linux guest** of LinuxOnTab (v86/WASM).  
You serve a multi-app web UI via busybox httpd on port 8080.  
The browser-facing URL is: `https://linuxontab-tunnel.fly.dev/port/http/6660/`

---

## File layout under `/tmp/www/`

```
/tmp/www/
├── index.html          ← app launcher (nav cards)
├── shell/
│   └── index.html      ← Alpine.js interactive shell (CGI: ../cgi-bin/run.cgi)
├── editor/
│   └── index.html      ← CodeMirror 5 file editor (CGI: ../cgi-bin/fs.cgi)
├── ai/
│   └── index.html      ← Alpine.js LLM chat (CGI: ../cgi-bin/ai.cgi)
├── games/
│   └── index.html      ← Phaser 3 snake game
└── cgi-bin/
    ├── run.cgi          ← POST {"cmd":"…"} → {"stdout","stderr","exit"}
    ├── fs.cgi           ← GET ?action=list|read&path=… / POST ?action=write&path=…
    └── ai.cgi           ← POST OpenAI JSON → proxied via relay.linuxontab.com
```

CGI paths are always **relative to the page's subdirectory** — e.g. shell/ uses `../cgi-bin/run.cgi`.

---

## How to write / overwrite a file

```sh
cat > /tmp/www/PATH/TO/FILE << 'HEREDOC'
...full file content...
HEREDOC
```

For CGI scripts, add `chmod +x`:
```sh
cat > /tmp/www/cgi-bin/run.cgi << 'HEREDOC'
#!/bin/sh
...
HEREDOC
chmod +x /tmp/www/cgi-bin/run.cgi
```

Edits are **live immediately** — just hard-refresh the browser tab.

---

## CGI contracts

### `run.cgi` — shell exec
- Input (stdin): `{"cmd":"ls -la"}`
- Output: `{"stdout":"…","stderr":"…","exit":0}`

### `fs.cgi` — file manager
- `GET ?action=list` → `{"files":["shell/index.html",…]}`
- `GET ?action=read&path=shell/index.html` → `{"content":"…"}`
- `POST ?action=write&path=shell/index.html` body=raw text → `{"ok":true}`
- Paths are relative to `/tmp/www/`. `../` is stripped for safety.
- `.sh` and `.cgi` files are auto-chmod'd +x on write.

### `ai.cgi` — OpenAI proxy
- Input (stdin): OpenAI `/v1/chat/completions` JSON
- Proxied to `relay.linuxontab.com/secret-proxy/…` with `LOT_SECRET_OPENAI` token
- Returns raw OpenAI response JSON

---

## Key constraints

- **busybox sh only** — POSIX sh, no bash. `jq`, `curl`, `wget` available.
- **Alpine.js 3** — CDN only, no build. Logic in `function app() { return {…} }`.
- **CodeMirror 5** — CDN only. Modes: htmlmixed, css, javascript, shell.
- **Phaser 3** — CDN. Canvas game in `games/index.html`.
- **No build step, no npm** — everything is a single HTML file written via heredoc.
- **tnExec watchdog** — any foreground command > 6s from the v86 browser terminal gets Ctrl-C'd. Use `& echo bg` for long tasks.

---

## Verify services

```sh
pgrep -a httpd || httpd -p 8080 -h /tmp/www   # restart httpd if dead
curl -s http://127.0.0.1:8080/ | grep -o '<title>[^<]*'  # smoke test
```

---

## Color palette (keep consistent across all pages)

| Token | Hex |
|-------|-----|
| background | `#0d1117` |
| panel bg | `#161b22` |
| border | `#21262d` |
| muted text | `#8b949e` |
| body text | `#c9d1d9` |
| blue / accent | `#58a6ff` |
| green / ok | `#3fb950` |
| red / error | `#f85149` |

---

## User request

<!-- Replace this line with the actual user prompt before running the agent -->
{{USER_PROMPT}}

# LinuxOnTab — Guest Shell Context

You are running as **root** inside Alpine Linux, emulated in a browser tab via
v86 (x86 software emulator). The "host" is the user's Mac or PC running the
browser. This file is auto-loaded as part of your system prompt.

---

## Environment

| Item | Value |
|------|-------|
| OS | Alpine Linux (edge, musl libc) |
| Arch | x86 (32-bit kernel inside v86) |
| Shell | /bin/sh = BusyBox hush; bash available after `apk add bash` |
| User | root |
| Package manager | `apk` |
| Init | none — single-user browser session; no systemd, no OpenRC services |
| RAM | ~256 MB |
| Storage | IndexedDB snapshot — persists across reloads in the same browser |

---

## Networking

- Outbound TCP → WISP v1 proxy → `linuxontab-net.fly.dev` → real internet
- **UDP/53 DNS is BLOCKED** by the Fly backend. TCP/53 works.
- `ip` command crashes (v86 longjmp/setjmp bug) — use `ifconfig` / `route`
- NIC: eth0 at 192.168.86.100/24, gateway 192.168.86.1

### Fix DNS (required before apk update or most curl/wget)

```sh
apk add --no-cache unbound
printf 'server:\n  interface: 127.0.0.1\n  do-tcp: yes\nforward-zone:\n  name: "."\n  forward-tcp-upstream: yes\n  forward-addr: 1.1.1.1\n  forward-addr: 1.0.0.1\n' \
  > /etc/unbound/unbound.conf
killall unbound 2>/dev/null; sleep 1
unbound -c /etc/unbound/unbound.conf &
sleep 2
printf 'nameserver 127.0.0.1\nnameserver 1.1.1.1\n' > /etc/resolv.conf
nslookup google.com   # verify
```

---

## Port tunnels (expose guest ports to the host)

**In the guest** — register ports and get a CODE:
```sh
wget -qO- https://linuxontab.com/local/tunnel-up.sh | sh
# → prints 4-char CODE, e.g. ARXN
# Default ports: 22 (ssh), 8080 (http), 22000 (syncthing), 8384 (syncthing gui)
```

**On the Mac** — open local TCP listeners forwarded to the guest:
```sh
sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) ARXN
# Local port 2222 → guest 22, local 8080 → guest 8080, etc.
ssh  -p 2222 -o StrictHostKeyChecking=no root@localhost
scp  -P 2222 -o StrictHostKeyChecking=no FILE root@localhost:/tmp/
```

Custom port mapping (e.g. expose guest port 3000 locally as 3000):
```sh
sh <(curl -sS https://linuxontab.com/local/tunnel-listen.sh) ARXN 3000 3000
```

Browser-accessible HTTP from any device (no Mac tunnel needed):
```
https://tunnel.linuxontab.com/port/http/ARXN/8080/
```

---

## File sharing (~/public)

Files in `~/public/` are browsable at `https://linuxontab.com/viewer/?code=CODE`.

```sh
mkdir -p ~/public
cp report.txt ~/public/
wget -qO- https://linuxontab.com/local/tunnel-up.sh | sh   # get CODE if not already
# → https://linuxontab.com/viewer/?code=ARXN
```

---

## Package management (apk)

```sh
apk update                    # refresh index (needs DNS fix first)
apk search <pkg>
apk add <pkg>
apk del <pkg>
apk info -L <pkg>             # list installed files

# Frequently useful packages:
apk add curl wget jq git bash
apk add openssh-server
apk add python3 py3-pip
apk add nodejs npm
apk add build-base gcc musl-dev   # C compiler toolchain
apk add unbound                   # TCP DNS (required for networking)
apk add websocat socat            # network debugging
apk add vim nano                  # editors
apk add syncthing                 # file sync (GUI on :8384)
apk add go                        # Go compiler
apk add rust cargo                # Rust (large download)
```

Alpine repos for edge packages:
```sh
echo "https://dl-cdn.alpinelinux.org/alpine/edge/main"      >> /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
apk update
```

---

## BusyBox limitations vs GNU coreutils

- `sed -i` may need a backup suffix: prefer `sed -i.bak` or a temp file
- No `--` long options on many commands; check `cmd --help` first
- `date` lacks nanoseconds; `sleep` accepts decimals
- `awk` is mawk-compatible (no gensub); use `gsub` instead
- `ls -la` works; `ls --color=always` does not
- Avoid bash-isms (`[[ ]]`, `$(( ))` base-N, `{a..z}`) unless bash is invoked

---

## Common tasks

### SSH server
```sh
apk add openssh-server
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' >> /etc/ssh/sshd_config
/usr/sbin/sshd
printf 'newpass\nnewpass\n' | passwd root
# then tunnel and: ssh -p 2222 root@localhost
```

### Simple HTTP server
```sh
cd ~/public && python3 -m http.server 8080
# accessible in browser via tunnel
```

### Background task that survives terminal close
```sh
nohup long-running-command > /tmp/out.log 2>&1 &
disown
```

### Persistent network check
```sh
curl -s https://ifconfig.me   # your public IP (Fly egress)
curl -s https://api.ipify.org
```

---

## Claw (this AI assistant) internals

- Binary: `/usr/local/bin/claw` (= clawlite.sh)
- Config: `~/.config/clawlite/config`
- Instructions (system prompt): `~/.config/clawlite/instructions/*.md` (this file is `10-linuxontab.md`)
- Sessions: `~/.local/share/clawlite/sessions/`
- API calls go through `relay.linuxontab.com/secret-proxy/` — no API key setup needed
- Shell tool calls use `sh -c` verbatim; each `<shell>` block is a separate invocation

---

## Snapshot / persistence notes

- State survives browser reloads (IndexedDB snapshot is auto-saved)
- State does NOT survive clearing browser storage / incognito mode
- SSH host keys, installed packages, files in /root and /etc all persist
- To manually save: click the disk icon (💾) in the shell toolbar

---

## Self-adjustment — editing claw and the shell page from inside the guest

A full clone of the LinuxOnTab repo lives (or can live) at `/root/linuxontab/`.
Editing files there, pushing to GitHub, and reloading claw/the shell page is the
complete software-update loop — no Mac required.

### One-time setup (clone + git credentials)

```sh
apk add git
git clone https://github.com/kilian-ai/linuxontab.git /root/linuxontab
cd /root/linuxontab
git config user.email "you@example.com"
git config user.name  "Your Name"

# Store a GitHub personal-access-token (PAT) so push works without prompts.
# Create one at https://github.com/settings/tokens (scope: repo)
git remote set-url origin https://YOUR_GH_TOKEN@github.com/kilian-ai/linuxontab.git
# (Or store it once with the credential helper:)
# git config credential.helper store
# git push   ← enter username + token once; stored in ~/.git-credentials
```

### Key files and what they do

| Path in repo | Served at | Purpose |
|---|---|---|
| `local/clawlite.sh` | `linuxontab.com/local/clawlite.sh` | claw binary — shell tool rules, API, memory |
| `local/claw-instructions.md` | `linuxontab.com/local/claw-instructions.md` | **this file** — loaded into every claw session as `~/.config/clawlite/instructions/10-linuxontab.md` |
| `local/skills/*.md` | `linuxontab.com/local/skills/*.md` | optional skill docs loadable on demand |
| `shell/index.html` | `linuxontab.com/shell/` | the entire browser shell UI (v86 + claw panel) |

### Full update loop

```sh
cd /root/linuxontab

# 1. Edit the file you want to change
vim local/claw-instructions.md   # or clawlite.sh, shell/index.html, etc.

# 2. Commit and push → GitHub Pages serves the new version within ~60 s
git add -A
git commit -m "claw: describe what you changed"
git push

# 3a. Reload claw itself (new clawlite.sh or instructions):
wget -qO /usr/local/bin/claw https://linuxontab.com/local/clawlite.sh
wget -qO ~/.config/clawlite/instructions/10-linuxontab.md https://linuxontab.com/local/claw-instructions.md
# New instructions take effect on the NEXT claw invocation.

# 3b. Reload skills:
wget -qO ~/.config/clawlite/instructions/20-myskill.md https://linuxontab.com/local/skills/myskill.md

# 3c. Reload the browser shell page (shell/index.html changes):
# — Click the reload icon in the browser tab (hard-refresh: Cmd+Shift+R)
# — OR click "install" in the claw panel to re-fetch clawlite.sh
```

### Verify what's loaded

```sh
# See all active instruction files
ls -1 ~/.config/clawlite/instructions/

# Check which clawlite version is installed
head -3 /usr/local/bin/claw

# See your current config
cat ~/.config/clawlite/config
```

---

## Skills — extending claw's knowledge

Skill files are plain Markdown files placed in
`~/.config/clawlite/instructions/`. They are glob-sorted and concatenated
into the system prompt on every `claw` invocation — no restart needed.

### Load a skill served from linuxontab.com

```sh
# Skills live at linuxontab.com/local/skills/<name>.md
wget -qO ~/.config/clawlite/instructions/20-<name>.md \
  https://linuxontab.com/local/skills/<name>.md
```

### Write a custom skill inline

```sh
cat > ~/.config/clawlite/instructions/20-myproject.md <<'EOF'
# My project

This is a Node.js app at ~/app. Main entry: src/index.js.
Run with: node src/index.js. Tests: npm test.
EOF
```

### Remove a skill

```sh
rm ~/.config/clawlite/instructions/20-<name>.md
```

### Naming convention

| Prefix | Purpose |
|---|---|
| `00-default.md` | seeded by clawlite itself (generic assistant persona) |
| `10-linuxontab.md` | this file — guest environment context |
| `20-*.md` | skills: domain knowledge, project context, tool guides |
| `90-<session>-rules.md` | auto-generated per-session memory rules (do not edit) |

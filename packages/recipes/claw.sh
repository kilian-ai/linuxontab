#!/bin/sh
# Recipe: claw — clawlite, a tiny POSIX-sh LLM agent/REPL (getclaw.site,
# github.com/kilian-ai/claw). Pure sh + curl + jq + awk: no Node, no npm,
# which is what makes an openclaw-style assistant possible in this guest.
#
#   export ANTHROPIC_API_KEY=sk-ant-...   (or OPENAI_API_KEY=sk-...)
#   claw -p anthropic        # or plain `claw` (default provider: openai)
#   claw "one-shot question"
#
# Runs on zsh, not the guest's /bin/sh. busybox hush on this no-MMU kernel
# re-parses functions from saved text in every child and drops heredoc
# bodies, so clawlite's prompt builders (functions with heredocs, called in
# $(...)) failed with "unexpected EOF in here document" and sent empty
# system prompts; the lean image's hush can't parse $(...) assignments at
# all. /usr/local/lib/claw/bin/sh is a symlink to zsh (zsh started as `sh`
# emulates sh), put first on PATH by the launcher, so the model's
# <shell> tool commands (`sh -c`) get the same working shell.
#
# The script is upstream's clawlite.sh unmodified; config, sessions and
# memory live under ~/.config/clawlite and ~/.local/share/clawlite. The
# model may run shell commands without asking (upstream default
# CLAW_YOLO=1; `claw --confirm` asks first).

NAME="claw"
VERSION="1.0.0-62f05f9"
DESCRIPTION="clawlite — tiny POSIX-sh LLM agent (Anthropic/OpenAI) with shell tool calls; set ANTHROPIC_API_KEY or OPENAI_API_KEY"
# Pinned to a commit on main: GitHub's source tarball for that commit.
SOURCE_URL="https://codeload.github.com/kilian-ai/claw/tar.gz/62f05f901885d620af420fdc852aa1e24bc0e666"
SOURCE_SHA256="f7793120c46ccd95ede975476efb44f49dd1f984af7cc720e43b74d5c44877d7"
DEPENDS="curl jq zsh"

build() {
    L="$STAGE/usr/local/lib/claw"
    mkdir -p "$L/bin" "$STAGE/usr/local/bin" "$STAGE/usr/local/share/doc/claw"
    install -m755 clawlite.sh "$L/claw.sh"
    # clawlite copies config.default from its own directory on first run
    install -m644 config.default "$L/config.default"
    ln -s /bin/zsh "$L/bin/sh"
    install -m644 README.md LICENSE "$STAGE/usr/local/share/doc/claw/"
    cat > "$STAGE/usr/local/bin/claw" <<'LAUNCHER'
#!/bin/sh
# claw (clawlite) on zsh in sh emulation: the guest's busybox hush can't run
# it (see /usr/local/lib/claw). `sh` inside claw, including the model's
# <shell> tool commands, resolves to the same zsh.
: "${HOME:=/root}"
PATH=/usr/local/lib/claw/bin:$PATH
export HOME PATH
exec /usr/local/lib/claw/bin/sh /usr/local/lib/claw/claw.sh "$@"
LAUNCHER
    chmod 755 "$STAGE/usr/local/bin/claw"
}

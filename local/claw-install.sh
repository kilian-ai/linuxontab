#!/bin/sh
# claw-install.sh — install claw into /usr/local/bin and exec it.
#
# Designed to be wget'd and piped to sh by the shell/index.html
# ?postboot= URL parameter, e.g.:
#
#   ?postboot=https://linuxontab.com/local/claw-install.sh
#
# (?postboot= auto-expands an http(s) URL to `wget -qO- <url> | sh`.)
#
# `exec claw` at the end replaces the pipeline shell with claw so it
# inherits the controlling TTY — claw is interactive and needs a real
# terminal for its REPL prompt; running it as a backgrounded child
# (`... | sh &`) leaves it without a TTY and Enter shows as ^M.

set -e
wget -qO /usr/local/bin/claw https://getclaw.site/claw
chmod +x /usr/local/bin/claw
echo "[claw-install] /usr/local/bin/claw installed ($(wc -c < /usr/local/bin/claw) bytes)"
exec claw

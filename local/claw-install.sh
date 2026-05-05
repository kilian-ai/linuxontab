#!/bin/sh
# claw-install.sh — fetch the claw binary into /usr/local/bin and make it
# executable. Designed to be wget'd and piped to sh, e.g.:
#
#   wget -qO- https://linuxontab.com/local/claw-install.sh | sh
#
# Used by the shell/index.html ?postboot= URL parameter for one-shot
# guest provisioning.

set -e
wget -qO /usr/local/bin/claw https://getclaw.site/claw && \
chmod +x /usr/local/bin/claw && \
echo "[claw-install] /usr/local/bin/claw installed ($(wc -c < /usr/local/bin/claw) bytes)"

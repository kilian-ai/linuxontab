#!/bin/sh
# Retry wrapper for `docker pull` to work around transient network/TLS failures
# Usage: docker-pull-retry [image]

set -eu

RETRIES=${RETRIES:-6}
DELAY=${DELAY:-5}

i=1
while [ "$i" -le "$RETRIES" ]; do
  if docker pull "$@"; then
    exit 0
  fi
  printf 'docker pull failed (attempt %s/%s) -- sleeping %s seconds\n' "$i" "$RETRIES" "$DELAY" >&2
  sleep "$DELAY"
  DELAY=$((DELAY * 2))
  i=$((i + 1))
done

printf 'docker pull failed after %s attempts\n' "$RETRIES" >&2
exit 1

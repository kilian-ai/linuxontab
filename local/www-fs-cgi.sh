#!/bin/sh
# fs.cgi — file manager CGI for /tmp/www
# GET  ?action=list              → {"files":["shell/index.html",...]}
# GET  ?action=read&path=...    → {"content":"..."}
# POST ?action=write&path=...   → {"ok":true}
#
# Paths are relative to ROOT. '..' segments are stripped for safety.

ROOT=/tmp/www

# Parse a single key from QUERY_STRING (busybox sh compatible)
qs() {
  printf '%s' "$QUERY_STRING" | tr '&' '\n' | grep "^$1=" | head -1 \
    | cut -d= -f2- \
    | sed 's/+/ /g; s/%2F/\//g; s/%2E/./g; s/%2D/-/g; s/%5F/_/g'
}

action=$(qs action)
rawpath=$(qs path)

# Strip any ../ traversal attempts
safepath=$(printf '%s' "$rawpath" | sed 's|\.\./||g; s|^\./||; s|^/||')

printf 'Content-Type: application/json\r\n\r\n'

case "$action" in

  list)
    FILES=$(find "$ROOT" -type f | sed "s|$ROOT/||" | sort \
      | grep -v '^$' | jq -R . | jq -sc '{"files":.}')
    printf '%s' "$FILES"
    ;;

  read)
    if [ -z "$safepath" ]; then
      printf '{"error":"missing path"}'
    else
      FULL="$ROOT/$safepath"
      if [ -f "$FULL" ]; then
        CONTENT=$(cat "$FULL")
        jq -n --arg c "$CONTENT" '{"content":$c}'
      else
        printf '{"error":"not found"}'
      fi
    fi
    ;;

  write)
    if [ -z "$safepath" ]; then
      printf '{"error":"missing path"}'
    else
      FULL="$ROOT/$safepath"
      mkdir -p "$(dirname "$FULL")"
      cat > "$FULL"
      # Auto-chmod CGI/shell scripts
      case "$safepath" in *.sh|*.cgi) chmod +x "$FULL" ;; esac
      printf '{"ok":true}'
    fi
    ;;

  *)
    printf '{"error":"unknown action: %s"}' "$action"
    ;;

esac

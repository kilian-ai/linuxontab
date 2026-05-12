#!/bin/sh
# LinuxOnTab CGI shell executor
# busybox httpd calls this for POST /cgi-bin/run.cgi
# stdin = request body, CONTENT_LENGTH = body size

BODY=$(cat)
CMD=$(printf '%s' "$BODY" | jq -r '.cmd // empty' 2>/dev/null)

if [ -z "$CMD" ]; then
  printf 'Content-Type: application/json\r\n\r\n{"error":"missing cmd","stdout":"","stderr":"","exit":1}'
  exit 0
fi

TMPOUT=$(mktemp)
TMPERR=$(mktemp)

eval "$CMD" >"$TMPOUT" 2>"$TMPERR"
EXIT=$?

OUT=$(cat "$TMPOUT")
ERR=$(cat "$TMPERR")
rm -f "$TMPOUT" "$TMPERR"

printf 'Content-Type: application/json\r\n\r\n'
jq -n --arg o "$OUT" --arg e "$ERR" --argjson x "$EXIT" \
  '{"stdout":$o,"stderr":$e,"exit":$x}'

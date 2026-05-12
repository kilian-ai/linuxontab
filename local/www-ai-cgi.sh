#!/bin/sh
# ai.cgi — proxy POST body to OpenAI via relay.linuxontab.com/secret-proxy
# The relay substitutes the token "LOT_SECRET_OPENAI" with the real API key.
# Browser sends: {"model":"gpt-4o-mini","messages":[...],"max_tokens":1024}
# Returns raw OpenAI response JSON.

RELAY='https://relay.linuxontab.com/secret-proxy/https%3A%2F%2Fapi.openai.com%2Fv1%2Fchat%2Fcompletions'

BODY=$(cat)

printf 'Content-Type: application/json\r\n\r\n'

curl -sS -m 60 -X POST "$RELAY" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer LOT_SECRET_OPENAI' \
  -d "$BODY"

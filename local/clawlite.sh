#!/bin/sh
# clawlite — minimalist multi-provider LLM REPL
# Pure POSIX sh + curl + jq. No Node, no npm, no TUI lib.
#
# Usage:
#   claw                          REPL, default session
#   claw "prompt here"            one-shot, prints reply, exits
#   echo "hi" | claw              one-shot from stdin
#   claw -s coding                REPL with named session
#   claw -i ~/notes/style.md      extra instruction file (repeatable)
#   claw -m gpt-5.5               model override (this run only)
#   claw -p openai|anthropic      provider override (this run only)
#   claw --no-memory              don't persist this turn
#   claw --no-instructions        skip system prompt entirely
#   claw --reset                  wipe current session and continue
#   claw --where                  print config + data dirs and exit
#
# Slash commands (REPL):
#   /exit  /quit                  leave
#   /help                         this help
#   /reset                        clear current session history
#   /list                         list saved sessions
#   /load <name>                  switch to session <name>
#   /save <name>                  copy current session to <name>
#   /model <name>                 switch model (this run only)
#   /provider openai|anthropic    switch provider (this run only)
#   /inst add <file>              add instruction file (this run only)
#   /inst rm  <file>              remove instruction file (this run only)
#   /inst list                    list active instruction files
#   /inst show                    print combined system prompt
#   /paste                        multi-line input (terminate with EOF)
#
# Files:
#   $XDG_CONFIG_HOME/clawlite/config            env-style settings
#   $XDG_CONFIG_HOME/clawlite/instructions/*.md auto-loaded as system prompt (alpha order)
#   $XDG_DATA_HOME/clawlite/sessions/<name>.json conversation history
#
# Required env (or put in config):
#   OPENAI_API_KEY      for provider=openai
#   ANTHROPIC_API_KEY   for provider=anthropic
#
# ----------------------------------------------------------------------

set -u

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/clawlite"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/clawlite"
SESS_DIR="$DATA_DIR/sessions"
INST_DIR="$CFG_DIR/instructions"
CFG_FILE="$CFG_DIR/config"

mkdir -p "$SESS_DIR" "$INST_DIR"

if [ ! -f "$CFG_FILE" ]; then
  cat > "$CFG_FILE" <<'EOF'
# clawlite config — sourced as POSIX shell.
PROVIDER=openai
MODEL_OPENAI=gpt-5.5
MODEL_ANTHROPIC=claude-sonnet-4-5
OPENAI_BASE_URL=https://api.openai.com/v1
ANTHROPIC_BASE_URL=https://api.anthropic.com/v1
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...
EOF
fi

if [ ! -f "$INST_DIR/00-default.md" ]; then
  cat > "$INST_DIR/00-default.md" <<'EOF'
You are a helpful assistant running in a sandboxed Linux terminal in a
browser tab (LinuxOnTab). Keep answers concise and copy-paste friendly.
Use plain ASCII output unless markdown is explicitly requested.
EOF
fi

# shellcheck disable=SC1090
. "$CFG_FILE"
: "${PROVIDER:=openai}"
: "${MODEL_OPENAI:=gpt-5.5}"
: "${MODEL_ANTHROPIC:=claude-sonnet-4-5}"
: "${OPENAI_BASE_URL:=https://api.openai.com/v1}"
: "${ANTHROPIC_BASE_URL:=https://api.anthropic.com/v1}"
: "${OPENAI_API_KEY:=}"
: "${ANTHROPIC_API_KEY:=}"

SESSION="default"
EXTRA_INST=""
NO_MEMORY=0
NO_INST=0
RESET=0
ONE_SHOT_MSG=""

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -s) SESSION="$2"; shift 2 ;;
    -i) EXTRA_INST="$EXTRA_INST $2"; shift 2 ;;
    -m) MODEL_OPENAI="$2"; MODEL_ANTHROPIC="$2"; shift 2 ;;
    -p) PROVIDER="$2"; shift 2 ;;
    --no-memory) NO_MEMORY=1; shift ;;
    --no-instructions) NO_INST=1; shift ;;
    --reset) RESET=1; shift ;;
    --where) printf 'CFG_DIR=%s\nDATA_DIR=%s\n' "$CFG_DIR" "$DATA_DIR"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ONE_SHOT_MSG="$*"; break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) ONE_SHOT_MSG="$*"; break ;;
  esac
done

SESS_FILE="$SESS_DIR/$SESSION.json"
[ "$RESET" = 1 ] && rm -f "$SESS_FILE"
[ -f "$SESS_FILE" ] || echo '[]' > "$SESS_FILE"

active_model() {
  if [ "$PROVIDER" = anthropic ]; then echo "$MODEL_ANTHROPIC"; else echo "$MODEL_OPENAI"; fi
}

build_system_prompt() {
  [ "$NO_INST" = 1 ] && return 0
  for f in "$INST_DIR"/*.md; do
    [ -f "$f" ] && cat "$f" && echo
  done
  for f in $EXTRA_INST; do
    [ -f "$f" ] && cat "$f" && echo
  done
}

append_msg() {
  [ "$NO_MEMORY" = 1 ] && return 0
  role="$1"; content="$2"
  tmp="$(mktemp)"
  jq --arg r "$role" --arg c "$content" '. + [{role:$r, content:$c}]' \
     "$SESS_FILE" > "$tmp" && mv "$tmp" "$SESS_FILE"
}

# ----------------------------------------------------------------------
# Provider: OpenAI (Chat Completions, streaming SSE)
# ----------------------------------------------------------------------
send_openai() {
  user_msg="$1"
  if [ -z "$OPENAI_API_KEY" ]; then
    echo "clawlite: OPENAI_API_KEY not set (edit $CFG_FILE or export it)" >&2
    return 1
  fi
  sys="$(build_system_prompt)"
  payload="$(
    jq -n \
      --arg model "$(active_model)" \
      --arg sys "$sys" \
      --arg user "$user_msg" \
      --slurpfile hist "$SESS_FILE" '
      {
        model: $model,
        stream: true,
        messages:
          ((if ($sys|length) > 0 then [{role:"system", content:$sys}] else [] end)
           + $hist[0]
           + [{role:"user", content:$user}])
      }'
  )"
  reply_file="$(mktemp)"
  : > "$reply_file"
  # shellcheck disable=SC2094
  curl -sN "$OPENAI_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @- <<EOF | while IFS= read -r line; do
$payload
EOF
      case "$line" in
        "data: [DONE]") break ;;
        "data: "*)
          chunk="${line#data: }"
          delta="$(printf '%s' "$chunk" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)"
          if [ -n "$delta" ]; then
            printf '%s' "$delta"
            printf '%s' "$delta" >> "$reply_file"
          fi
          err="$(printf '%s' "$chunk" | jq -r '.error.message // empty' 2>/dev/null)"
          [ -n "$err" ] && printf '\n[openai error: %s]\n' "$err" >&2
          ;;
      esac
    done
  echo
  reply="$(cat "$reply_file")"
  rm -f "$reply_file"
  if [ -n "$reply" ]; then
    append_msg user      "$user_msg"
    append_msg assistant "$reply"
  fi
}

# ----------------------------------------------------------------------
# Provider: Anthropic (Messages API, streaming SSE)
# ----------------------------------------------------------------------
send_anthropic() {
  user_msg="$1"
  if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "clawlite: ANTHROPIC_API_KEY not set (edit $CFG_FILE or export it)" >&2
    return 1
  fi
  sys="$(build_system_prompt)"
  payload="$(
    jq -n \
      --arg model "$(active_model)" \
      --arg sys "$sys" \
      --arg user "$user_msg" \
      --slurpfile hist "$SESS_FILE" '
      {
        model: $model,
        stream: true,
        max_tokens: 4096,
        system: $sys,
        messages: ($hist[0] + [{role:"user", content:$user}])
      }'
  )"
  reply_file="$(mktemp)"
  : > "$reply_file"
  curl -sN "$ANTHROPIC_BASE_URL/messages" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    --data-binary @- <<EOF | while IFS= read -r line; do
$payload
EOF
      case "$line" in
        "data: "*)
          chunk="${line#data: }"
          delta="$(printf '%s' "$chunk" | jq -r 'select(.type=="content_block_delta") | .delta.text // empty' 2>/dev/null)"
          if [ -n "$delta" ]; then
            printf '%s' "$delta"
            printf '%s' "$delta" >> "$reply_file"
          fi
          err="$(printf '%s' "$chunk" | jq -r 'select(.type=="error") | .error.message // empty' 2>/dev/null)"
          [ -n "$err" ] && printf '\n[anthropic error: %s]\n' "$err" >&2
          ;;
      esac
    done
  echo
  reply="$(cat "$reply_file")"
  rm -f "$reply_file"
  if [ -n "$reply" ]; then
    append_msg user      "$user_msg"
    append_msg assistant "$reply"
  fi
}

send() {
  case "$PROVIDER" in
    openai)    send_openai    "$1" ;;
    anthropic) send_anthropic "$1" ;;
    *) echo "clawlite: unknown provider '$PROVIDER'" >&2; return 1 ;;
  esac
}

# ----------------------------------------------------------------------
# Slash command dispatch. Returns 2 to signal exit.
# ----------------------------------------------------------------------
handle_slash() {
  cmd="$1"
  case "$cmd" in
    /exit|/quit) return 2 ;;
    /help)       usage ;;
    /reset)      echo '[]' > "$SESS_FILE"; echo "(session reset: $SESSION)" ;;
    /list)
      ls -1 "$SESS_DIR" 2>/dev/null | sed 's/\.json$//' | grep -v '^$' || echo "(no sessions)"
      ;;
    "/load "*)
      n="${cmd#/load }"
      SESSION="$n"; SESS_FILE="$SESS_DIR/$n.json"
      [ -f "$SESS_FILE" ] || echo '[]' > "$SESS_FILE"
      echo "(loaded session: $n)"
      ;;
    "/save "*)
      n="${cmd#/save }"
      cp "$SESS_FILE" "$SESS_DIR/$n.json"
      echo "(saved as: $n)"
      ;;
    "/model "*)
      n="${cmd#/model }"
      if [ "$PROVIDER" = anthropic ]; then MODEL_ANTHROPIC="$n"; else MODEL_OPENAI="$n"; fi
      echo "(model: $n)"
      ;;
    /model)     echo "current model: $(active_model)" ;;
    "/provider "*)
      n="${cmd#/provider }"
      PROVIDER="$n"
      echo "(provider: $n, model: $(active_model))"
      ;;
    /provider)  echo "current provider: $PROVIDER" ;;
    "/inst add "*)
      f="${cmd#/inst add }"
      if [ -f "$f" ]; then EXTRA_INST="$EXTRA_INST $f"; echo "(added: $f)"
      else echo "(no such file: $f)"; fi
      ;;
    "/inst rm "*)
      f="${cmd#/inst rm }"; new=""
      for x in $EXTRA_INST; do [ "$x" != "$f" ] && new="$new $x"; done
      EXTRA_INST="$new"; echo "(removed: $f)"
      ;;
    "/inst list"|"/inst")
      for f in "$INST_DIR"/*.md; do [ -f "$f" ] && echo "$f"; done
      for f in $EXTRA_INST; do echo "$f  (session)"; done
      ;;
    "/inst show")
      build_system_prompt
      ;;
    /paste)
      echo "(multi-line — end with a single line containing only EOF)"
      buf=""
      while IFS= read -r ln; do
        [ "$ln" = "EOF" ] && break
        buf="$buf$ln
"
      done
      [ -n "$buf" ] && send "$buf"
      ;;
    /*) echo "unknown command: $cmd  (try /help)" ;;
    *)  return 1 ;;
  esac
  return 0
}

# ----------------------------------------------------------------------
# One-shot mode (arg or stdin)
# ----------------------------------------------------------------------
if [ -n "$ONE_SHOT_MSG" ]; then
  send "$ONE_SHOT_MSG"
  exit 0
fi
if [ ! -t 0 ]; then
  msg="$(cat)"
  if [ -n "$msg" ]; then send "$msg"; exit 0; fi
fi

# ----------------------------------------------------------------------
# REPL
# ----------------------------------------------------------------------
printf 'clawlite  provider=%s  model=%s  session=%s\n' \
  "$PROVIDER" "$(active_model)" "$SESSION"
printf '(/help for commands, /exit to quit)\n'

while :; do
  printf '\n> '
  IFS= read -r line || { echo; break; }
  [ -z "$line" ] && continue
  case "$line" in
    /*)
      handle_slash "$line"; rc=$?
      [ "$rc" = 2 ] && break
      continue
      ;;
  esac
  send "$line" || true
done

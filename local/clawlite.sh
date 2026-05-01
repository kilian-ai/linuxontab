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
#   claw --no-tools               disable shell tool calling
#   claw --yolo                   run shell tool calls without confirmation
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
#   /tools on|off                 toggle shell tool calling
#   /yolo on|off                  toggle confirm prompt for shell tools
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
# Shell tool calling: model can run commands via <shell>...</shell> blocks.
TOOLS=1
TOOL_MAX_ITERS=5
TOOL_OUTPUT_LIMIT=8192
# Set CLAW_YOLO=1 to skip the per-command confirm prompt.
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
: "${TOOLS:=1}"
: "${TOOL_MAX_ITERS:=5}"
: "${TOOL_OUTPUT_LIMIT:=8192}"
: "${CLAW_YOLO:=0}"

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
    --no-tools) TOOLS=0; shift ;;
    --yolo) CLAW_YOLO=1; shift ;;
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

tool_system_prompt() {
  [ "$TOOLS" = 1 ] || return 0
  cat <<'EOF'

# Shell tool

You can execute shell commands in the user's current shell by emitting one
or more blocks of the form:

<shell>
command here
</shell>

Rules:
- Only emit a <shell> block when running a command is genuinely needed to
  answer the user. For purely informational answers, do not emit one.
- The block contents are passed verbatim to `sh -c`. Combined stdout+stderr
  (truncated) and the exit code are returned in the next turn inside
  <shell-result exit=N> ... </shell-result>.
- Multiple <shell> blocks in one reply are run sequentially.
- Do NOT wrap <shell> blocks in markdown code fences. Emit the raw tags.
- After you receive shell-result(s), continue the conversation: either run
  more commands, or summarize the outcome for the user. Stop emitting
  <shell> blocks once you have what you need.
- Prefer non-interactive, idempotent commands. Avoid destructive operations
  unless the user explicitly asked for them.
EOF
}

build_system_prompt() {
  [ "$NO_INST" = 1 ] && return 0
  for f in "$INST_DIR"/*.md; do
    [ -f "$f" ] && cat "$f" && echo
  done
  for f in $EXTRA_INST; do
    [ -f "$f" ] && cat "$f" && echo
  done
  tool_system_prompt
}

append_msg() {
  [ "$NO_MEMORY" = 1 ] && return 0
  role="$1"; content="$2"
  tmp="$(mktemp)"
  jq --arg r "$role" --arg c "$content" '. + [{role:$r, content:$c}]' \
     "$SESS_FILE" > "$tmp" && mv "$tmp" "$SESS_FILE"
}

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------
# Run curl, strip CR from SSE, tee raw to debug log if CLAW_DEBUG=1.
# Reads from stdin (the request body file), writes SSE lines to stdout.
stream_curl() {
  url="$1"; shift
  body="$1"; shift
  if [ "${CLAW_DEBUG:-0}" = 1 ]; then
    raw="$(mktemp)"
    curl -sS -N "$url" "$@" --data-binary @"$body" | tee "$raw" | tr -d '\r'
    echo "[claw-debug] raw response saved to $raw" >&2
  else
    curl -sS -N "$url" "$@" --data-binary @"$body" | tr -d '\r'
  fi
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
  body="$(mktemp)"
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
    }' > "$body"
  reply_file="$(mktemp)"
  : > "$reply_file"
  saw_data=0
  raw_acc="$(mktemp)"
  stream_curl "$OPENAI_BASE_URL/chat/completions" "$body" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    | tee "$raw_acc" | while IFS= read -r line; do
      case "$line" in
        "data: [DONE]") break ;;
        "data: "*)
          chunk="${line#data: }"
          delta="$(printf '%s' "$chunk" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)"
          if [ -n "$delta" ]; then
            printf '%s' "$delta"
            printf '%s' "$delta" >> "$reply_file"
            echo 1 > "${reply_file}.saw"
          fi
          err="$(printf '%s' "$chunk" | jq -r '.error.message // empty' 2>/dev/null)"
          [ -n "$err" ] && printf '\n[openai error: %s]\n' "$err" >&2
          ;;
      esac
    done
  echo
  # If no streamed delta arrived, the response was probably a plain JSON
  # error (HTTP 400/401/etc). Show it.
  [ -f "${reply_file}.saw" ] && saw_data=1
  if [ "$saw_data" = 0 ]; then
    msg="$(jq -r '.error.message // .error // empty' "$raw_acc" 2>/dev/null)"
    if [ -n "$msg" ]; then
      printf '[openai error] %s\n' "$msg" >&2
    else
      echo "[clawlite] no response received. raw output:" >&2
      sed 's/^/  /' "$raw_acc" >&2
    fi
  fi
  reply="$(cat "$reply_file")"
  rm -f "$reply_file" "${reply_file}.saw" "$body" "$raw_acc"
  if [ -n "$reply" ]; then
    append_msg user      "$user_msg"
    append_msg assistant "$reply"
  fi
  if [ -n "${REPLY_OUT:-}" ]; then
    printf '%s' "$reply" > "$REPLY_OUT"
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
  body="$(mktemp)"
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
    }' > "$body"
  reply_file="$(mktemp)"
  : > "$reply_file"
  raw_acc="$(mktemp)"
  stream_curl "$ANTHROPIC_BASE_URL/messages" "$body" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    | tee "$raw_acc" | while IFS= read -r line; do
      case "$line" in
        "data: "*)
          chunk="${line#data: }"
          delta="$(printf '%s' "$chunk" | jq -r 'select(.type=="content_block_delta") | .delta.text // empty' 2>/dev/null)"
          if [ -n "$delta" ]; then
            printf '%s' "$delta"
            printf '%s' "$delta" >> "$reply_file"
            echo 1 > "${reply_file}.saw"
          fi
          err="$(printf '%s' "$chunk" | jq -r 'select(.type=="error") | .error.message // empty' 2>/dev/null)"
          [ -n "$err" ] && printf '\n[anthropic error: %s]\n' "$err" >&2
          ;;
      esac
    done
  echo
  if [ ! -f "${reply_file}.saw" ]; then
    msg="$(jq -r '.error.message // .error // empty' "$raw_acc" 2>/dev/null)"
    if [ -n "$msg" ]; then
      printf '[anthropic error] %s\n' "$msg" >&2
    else
      echo "[clawlite] no response received. raw output:" >&2
      sed 's/^/  /' "$raw_acc" >&2
    fi
  fi
  reply="$(cat "$reply_file")"
  rm -f "$reply_file" "${reply_file}.saw" "$body" "$raw_acc"
  if [ -n "$reply" ]; then
    append_msg user      "$user_msg"
    append_msg assistant "$reply"
  fi
  if [ -n "${REPLY_OUT:-}" ]; then
    printf '%s' "$reply" > "$REPLY_OUT"
  fi
}

send_provider() {
  case "$PROVIDER" in
    openai)    send_openai    "$1" ;;
    anthropic) send_anthropic "$1" ;;
    *) echo "clawlite: unknown provider '$PROVIDER'" >&2; return 1 ;;
  esac
}

# Extract <shell>...</shell> blocks from $1 into numbered files in dir $2.
# Prints the count.
extract_shell_blocks() {
  awk -v dir="$2" '
    BEGIN { RS="<shell>"; n=0 }
    NR>1 {
      p = index($0, "</shell>")
      if (p>0) {
        n++
        f = sprintf("%s/cmd-%03d", dir, n)
        printf "%s", substr($0, 1, p-1) > f
        close(f)
      }
    }
    END { print n }
  ' "$1"
}

# Strip leading/trailing whitespace from a file's contents.
trim_cmd() {
  awk 'BEGIN{ORS=""} {buf=buf $0 "\n"} END{
    sub(/^[ \t\r\n]+/,"",buf); sub(/[ \t\r\n]+$/,"",buf); print buf
  }' "$1"
}

run_tool_loop() {
  reply_file="$1"
  iter=0
  while [ "$iter" -lt "$TOOL_MAX_ITERS" ]; do
    workdir="$(mktemp -d)"
    n=$(extract_shell_blocks "$reply_file" "$workdir")
    if [ "${n:-0}" -eq 0 ]; then
      rm -rf "$workdir"
      return 0
    fi
    iter=$((iter+1))
    results_file="$(mktemp)"
    : > "$results_file"
    i=1
    while [ "$i" -le "$n" ]; do
      cmd_path="$workdir/cmd-$(printf '%03d' "$i")"
      cmd="$(trim_cmd "$cmd_path")"
      printf '\n\033[36m[claw] tool call %d/%d:\033[0m\n%s\n' "$i" "$n" "$cmd" >&2
      run_it=1
      if [ "$CLAW_YOLO" != 1 ]; then
        if [ -r /dev/tty ]; then
          printf '\033[33m[claw] run? [y/N/a=yes-all/q=stop] \033[0m' >&2
          ans=""
          read -r ans </dev/tty || ans=""
        else
          ans="n"
        fi
        case "$ans" in
          a|A) CLAW_YOLO=1; run_it=1 ;;
          y|Y) run_it=1 ;;
          q|Q) run_it=0; SKIP_REST=1 ;;
          *)   run_it=0 ;;
        esac
      fi
      out_file="$(mktemp)"
      if [ "$run_it" = 1 ]; then
        sh -c "$cmd" >"$out_file" 2>&1
        ec=$?
      else
        echo "[skipped by user]" > "$out_file"
        ec=-1
      fi
      bytes=$(wc -c < "$out_file" | tr -d ' ')
      if [ "$bytes" -gt "$TOOL_OUTPUT_LIMIT" ]; then
        out="$(head -c "$TOOL_OUTPUT_LIMIT" "$out_file")
[...truncated, $bytes bytes total]"
      else
        out="$(cat "$out_file")"
      fi
      printf '\033[2m%s\033[0m\n[exit %s]\n' "$out" "$ec" >&2
      {
        printf '<shell-result exit=%s>\n' "$ec"
        printf '%s\n' "$out"
        printf '</shell-result>\n'
      } >> "$results_file"
      rm -f "$out_file"
      i=$((i+1))
      if [ "${SKIP_REST:-0}" = 1 ]; then break; fi
    done
    rm -rf "$workdir"
    if [ "${SKIP_REST:-0}" = 1 ]; then
      rm -f "$results_file"; SKIP_REST=0
      return 0
    fi
    follow_up="$(cat "$results_file")"
    rm -f "$results_file"
    REPLY_OUT="$reply_file"
    : > "$reply_file"
    send_provider "$follow_up" || return 1
  done
  echo "\n[claw] tool loop hit max iterations ($TOOL_MAX_ITERS)" >&2
  return 0
}

send() {
  if [ "$TOOLS" = 1 ]; then
    reply_file="$(mktemp)"
    REPLY_OUT="$reply_file"
    send_provider "$1" || { rm -f "$reply_file"; REPLY_OUT=""; return 1; }
    REPLY_OUT=""
    run_tool_loop "$reply_file"
    rc=$?
    rm -f "$reply_file"
    return $rc
  else
    send_provider "$1"
  fi
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
    "/tools "*)
      n="${cmd#/tools }"
      case "$n" in
        on|1|true)  TOOLS=1; echo "(tools: on)" ;;
        off|0|false) TOOLS=0; echo "(tools: off)" ;;
        *) echo "(usage: /tools on|off)" ;;
      esac
      ;;
    /tools) echo "tools: $([ "$TOOLS" = 1 ] && echo on || echo off)" ;;
    "/yolo "*)
      n="${cmd#/yolo }"
      case "$n" in
        on|1|true)  CLAW_YOLO=1; echo "(yolo: on — shell tools run without confirm)" ;;
        off|0|false) CLAW_YOLO=0; echo "(yolo: off)" ;;
        *) echo "(usage: /yolo on|off)" ;;
      esac
      ;;
    /yolo) echo "yolo: $([ "$CLAW_YOLO" = 1 ] && echo on || echo off)" ;;
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
printf 'clawlite  provider=%s  model=%s  session=%s  tools=%s%s\n' \
  "$PROVIDER" "$(active_model)" "$SESSION" \
  "$([ "$TOOLS" = 1 ] && echo on || echo off)" \
  "$([ "$CLAW_YOLO" = 1 ] && echo ' yolo' || echo '')"
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

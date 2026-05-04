#!/usr/bin/env bash
# orchestrator-bot/chat-watcher.sh — tail orchestrator JSONLs and push
# assistant text turns to the user's Telegram chat. Closes the
# silent-processing gap: without this, orchestrator's mid-stream
# narration + clarification requests + final aggregates live in JSONL
# only and never reach the user.
#
# How it works:
#   - Polls ~/.claude/projects/ for orchestrator session JSONLs
#     (project dirs whose name contains "arra-oracle-v3-wt-*-inbox-*"
#     since orchestrator's wakes spawn worktrees with that suffix).
#   - For each JSONL, keeps a per-file byte cursor at
#     ~/.cache/orchestrator-bot/cursor.<session-id>.
#   - On a new JSONL (no cursor): record cursor at EOF — don't push old
#     content. Subsequent ticks pick up new lines only.
#   - On an existing JSONL: parse new lines, extract assistant text
#     blocks (skip tool_use, tool_result, thinking), push to Telegram.
#
# State at ~/.cache/orchestrator-bot/.

set -u
exec </dev/null

ENV_FILE=${ENV_FILE:-$HOME/.cache/orchestrator-bot/.env}
[ -f "$ENV_FILE" ] || { echo "ERR: $ENV_FILE not found" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

TOKEN=${TELEGRAM_BOT_TOKEN:?missing TELEGRAM_BOT_TOKEN in env}
CHAT=${TELEGRAM_CHAT_ID:?missing TELEGRAM_CHAT_ID in env}

STATE_DIR=${STATE_DIR:-$HOME/.cache/orchestrator-bot}
mkdir -p "$STATE_DIR"
LOG_FILE=${LOG_FILE:-$STATE_DIR/chat-watcher.log}
PID_FILE=${PID_FILE:-$STATE_DIR/chat-watcher.pid}

CLAUDE_PROJECTS=${CLAUDE_PROJECTS:-$HOME/.claude/projects}
POLL_INTERVAL=${POLL_INTERVAL:-3}     # tail every 3s for low-latency Telegram echo
RECENT_WINDOW_MIN=${RECENT_WINDOW_MIN:-30}
# Suppress very short assistant turns from reaching Telegram. Default 0
# preserves the previous "every text turn → user" behavior. Raise to ~30
# to drop short status pings ("checking…", "ok", emoji-only) that the
# orchestrator emits between tool calls and that clutter the Telegram chat
# without adding info the user couldn't infer from the next substantive
# message. The threshold counts characters of the trimmed message.
PUSH_MIN_CHARS=${PUSH_MIN_CHARS:-0}

# Orchestrator JSONLs live under project dirs that match this pattern
# (worktree path encoded by claude). Adjust if orchestrator deployment
# changes (e.g. peer nodes in different paths).
ORCHESTRATOR_DIR_GLOB="${CLAUDE_PROJECTS}/-Users-dev01-Code-github-com-Soul-Brews-Studio-arra-oracle-v3*inbox-*"

# ── helpers ────────────────────────────────────────────────────────────────

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

send_tg() {
  local text="$1"
  if [ ${#text} -gt 3900 ]; then text="${text:0:3850}

[…truncated]"; fi
  local resp
  resp=$(curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=$CHAT" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$text" 2>&1)
  if ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
    log "send_tg failed: $(echo "$resp" | head -c 200)"
  fi
}

# Extract orchestrator session id (filename without .jsonl) from path
session_id_of() { basename "$1" .jsonl; }

# Find recently active orchestrator JSONLs
find_active_jsonls() {
  find $ORCHESTRATOR_DIR_GLOB -name '*.jsonl' \
    -type f -mmin -$RECENT_WINDOW_MIN 2>/dev/null
}

# Process new lines in a JSONL since its cursor; emit assistant text turns to TG
process_jsonl() {
  local jsonl="$1"
  local sid=$(session_id_of "$jsonl")
  local cursor_file="$STATE_DIR/cursor.$sid"
  local cur_size=$(stat -f %z "$jsonl" 2>/dev/null || stat -c %s "$jsonl" 2>/dev/null)

  if [ ! -f "$cursor_file" ]; then
    # First time we see this JSONL. Record EOF as cursor — DON'T push backlog.
    # Subsequent ticks will pick up only new lines.
    echo "$cur_size" > "$cursor_file"
    log "[$sid] new session — cursor at EOF ($cur_size bytes)"
    send_tg "🟡 [orchestrator] new session started — sid=<code>$(echo "$sid" | head -c 8)…</code>"
    return
  fi

  local last=$(cat "$cursor_file" 2>/dev/null || echo 0)
  if [ "$cur_size" -le "$last" ]; then return; fi

  # Read new bytes since last cursor
  local new_lines
  new_lines=$(tail -c +$((last + 1)) "$jsonl" 2>/dev/null)
  echo "$cur_size" > "$cursor_file"

  # Each line is a JSON object. Extract assistant text turns.
  printf '%s\n' "$new_lines" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    local kind=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
    [ "$kind" != "assistant" ] && continue

    # Each assistant message has .message.content[] — push only text blocks.
    local texts
    texts=$(printf '%s' "$line" | jq -r '.message.content[]? | select(.type == "text") | .text' 2>/dev/null)
    [ -z "$texts" ] && continue

    # Trim leading/trailing whitespace
    local trimmed
    trimmed=$(printf '%s' "$texts" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$trimmed" ] && continue

    local nchars=$(printf '%s' "$trimmed" | wc -c | tr -d ' ')
    if [ "$PUSH_MIN_CHARS" -gt 0 ] && [ "$nchars" -lt "$PUSH_MIN_CHARS" ]; then
      log "[$sid] skip text ($nchars chars < PUSH_MIN_CHARS=$PUSH_MIN_CHARS)"
      continue
    fi
    log "[$sid] push text ($nchars chars)"

    local escaped
    escaped=$(printf '%s' "$trimmed" | html_escape)
    send_tg "🤖 <b>[orchestrator]</b>
$escaped"
  done
}

# ── main loop ──────────────────────────────────────────────────────────────

run_loop() {
  log "chat-watcher starting (poll=${POLL_INTERVAL}s, recent=${RECENT_WINDOW_MIN}m, chat=$CHAT)"
  while true; do
    local jsonls
    jsonls=$(find_active_jsonls)
    [ -z "$jsonls" ] && { sleep "$POLL_INTERVAL"; continue; }
    while IFS= read -r jsonl; do
      [ -f "$jsonl" ] || continue
      process_jsonl "$jsonl"
    done <<< "$jsonls"
    sleep "$POLL_INTERVAL"
  done
}

# Same shape as bot.sh / inbox-watcher: defend against orphan instances
# whose pidfile got cleaned but whose process is still tailing JSONLs.
# Two chat-watchers would push every assistant turn to Telegram twice.
find_other_daemons() {
  local base=$(basename "$0")
  local p cmd ppid out=""
  for p in $(pgrep -f "$base" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    ppid=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
    [ "$ppid" = "$$" ] && continue
    cmd=$(ps -p "$p" -o command= 2>/dev/null)
    case "$cmd" in
      bash" "*"$base"*|*/bash" "*"$base"*) out="$out $p" ;;
    esac
  done
  echo "${out# }"
}

case ${1:-loop} in
  loop|start)
    others=$(find_other_daemons)
    if [ -n "$others" ]; then
      echo "another $(basename "$0") is already running (pid=$others)" >&2
      exit 1
    fi
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "already running: $(cat "$PID_FILE")" >&2
      exit 1
    fi
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"' EXIT
    trap 'rm -f "$PID_FILE"; exit 0' INT TERM
    run_loop
    ;;
  stop)
    others=$(find_other_daemons)
    [ -f "$PID_FILE" ] && others="$others $(cat "$PID_FILE" 2>/dev/null)"
    others=$(printf '%s\n' $others | awk 'NF && !seen[$0]++' | tr '\n' ' ')
    if [ -z "${others// /}" ]; then
      echo "not running"
      rm -f "$PID_FILE"
      exit 0
    fi
    for p in $others; do
      [ -z "$p" ] && continue
      if kill -TERM "$p" 2>/dev/null; then
        echo "stopped pid=$p"
      else
        echo "kill $p failed (process gone?)" >&2
      fi
    done
    rm -f "$PID_FILE"
    ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "running: pid=$(cat "$PID_FILE")"
    else
      echo "stopped"
    fi
    echo "tracked sessions:"
    find "$STATE_DIR" -maxdepth 1 -name 'cursor.*' 2>/dev/null | while read -r f; do
      printf '  %s @ %s bytes\n' "${f#"$STATE_DIR/cursor."}" "$(cat "$f" 2>/dev/null)"
    done
    ;;
  reset-cursors)
    rm -f "$STATE_DIR/cursor."* && echo "cursors cleared"
    ;;
  *)
    cat <<USAGE >&2
usage: $0 {loop|start|stop|status|reset-cursors}
  loop / start     run the watcher daemon (foreground)
  stop             kill running daemon by pid file
  status           show pid + tracked session cursors
  reset-cursors    clear all cursors (next tick re-baselines)
env: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, POLL_INTERVAL, RECENT_WINDOW_MIN
USAGE
    exit 2
    ;;
esac

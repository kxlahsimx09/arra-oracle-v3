#!/usr/bin/env bash
# orchestrator-bot.sh — Telegram daemon for the orchestrator role.
#
# Receives user messages on chat 2002026175, parses commands or treats as
# plain-text dispatch input, writes envelopes to ~/.arra-oracle-v2/ψ/inbox/
# for-orchestrator/ which the inbox-watcher (§11i) wakes the orchestrator
# session to process. Mirrors the brew-ops-bot pattern but focused on the
# single user→orchestrator chat (no per-chat-pane management here).
#
# Commands (Telegram surface):
#   /help              — show this help
#   /threads           — list parent threads opened by this chat (newest-first)
#   /use <N>           — set active parent thread → next plain text continues #N
#   /new               — clear active thread → next plain text starts fresh request
#   /peek <N>          — preview last 3 messages of thread #N (no switch)
#   /close <N>         — mark thread #N closed (orchestrator ratifies)
#   /cancel <N>        — write a cancellation envelope for thread #N
#   /status            — active thread, pending sub-threads, watcher alerts
#   /escalations       — list unresolved [ESCALATE_TO_HUMAN:*] markers
#   <plain text>       — append to active thread, OR start fresh request
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
LOG_FILE=${LOG_FILE:-$STATE_DIR/bot.log}
PID_FILE=${PID_FILE:-$STATE_DIR/bot.pid}
LAST_UPDATE_FILE=$STATE_DIR/last-update-id
ACTIVE_THREAD_FILE=$STATE_DIR/active-thread.$CHAT
KNOWN_THREADS_FILE=$STATE_DIR/known-threads.$CHAT

INBOX_DIR=${INBOX_DIR:-$HOME/.arra-oracle-v2/ψ/inbox/for-orchestrator}
ORACLE_API=${ORACLE_API:-http://localhost:47778/api}

mkdir -p "$INBOX_DIR"
touch "$KNOWN_THREADS_FILE"

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
    log "send_tg failed: $(echo "$resp" | head -c 300)"
  fi
}

# Read the active thread id (or empty if unset)
get_active_thread() { [ -f "$ACTIVE_THREAD_FILE" ] && cat "$ACTIVE_THREAD_FILE" || echo ""; }
set_active_thread() { echo "$1" > "$ACTIVE_THREAD_FILE"; }
clear_active_thread() { rm -f "$ACTIVE_THREAD_FILE"; }

# Add to known-threads (idempotent — dedupes by id)
add_known_thread() {
  local id="$1" title="$2" status="${3:-active}" opened="${4:-$(date -Iseconds)}"
  grep -v "^${id}|" "$KNOWN_THREADS_FILE" 2>/dev/null > "$KNOWN_THREADS_FILE.tmp" || true
  printf '%s|%s|%s|%s\n' "$id" "$title" "$status" "$opened" >> "$KNOWN_THREADS_FILE.tmp"
  mv "$KNOWN_THREADS_FILE.tmp" "$KNOWN_THREADS_FILE"
}

# Refresh known-threads with live status from oracle API (best effort)
refresh_known_threads() {
  [ ! -s "$KNOWN_THREADS_FILE" ] && return
  local tmp="$KNOWN_THREADS_FILE.refresh"
  : > "$tmp"
  while IFS='|' read -r id title old_status opened; do
    [ -z "$id" ] && continue
    local cur=$(curl -sf "$ORACLE_API/forum/thread/$id" 2>/dev/null | jq -r '.thread.status // empty' 2>/dev/null)
    [ -z "$cur" ] && cur="$old_status"
    printf '%s|%s|%s|%s\n' "$id" "$title" "$cur" "$opened" >> "$tmp"
  done < "$KNOWN_THREADS_FILE"
  mv "$tmp" "$KNOWN_THREADS_FILE"
}

# Write a request envelope (plain-text dispatch from user)
write_envelope() {
  local text="$1" parent_thread="$2"
  local ts=$(date '+%Y-%m-%d_%H-%M')
  local fname="${ts}_from-user_request"
  [ -n "$parent_thread" ] && fname="${ts}_from-user_thread-${parent_thread}_continuation"
  fname="${fname}.md"
  local path="$INBOX_DIR/$fname"

  {
    echo "---"
    echo "from: user"
    echo "from_role: human"
    echo "to: orchestrator"
    echo "to_role: orchestrator"
    echo "type: consult"
    [ -n "$parent_thread" ] && echo "parent_thread: $parent_thread"
    [ -n "$parent_thread" ] && echo "parent_oracle: orchestrator"
    echo "subject: $(echo "$text" | head -c 100 | tr '\n' ' ')"
    echo "needs_response: true"
    echo "priority: normal"
    echo "created: $(date -Iseconds)"
    echo "source: telegram-chat-$CHAT"
    echo "---"
    echo
    echo "# User request via Telegram"
    echo
    echo "$text"
  } > "$path"
  log "wrote envelope: $fname (parent=${parent_thread:-none})"
  echo "$path"
}

# ── command handlers ───────────────────────────────────────────────────────

cmd_help() {
  send_tg "$(cat <<EOF
<b>Orchestrator commands</b>

<code>/threads</code> — list open parent threads (✓ = active)
<code>/use N</code>  — switch active thread to #N
<code>/new</code>    — clear active, next message starts fresh request
<code>/peek N</code> — preview last 3 messages of #N (no switch)
<code>/close N</code> — mark #N closed
<code>/cancel N</code> — request orchestrator to cancel sub-thread #N
<code>/status</code> — active + pending sub-threads + watcher alerts
<code>/escalations</code> — unresolved escalations across fleet
<code>/cleanup</code> — one-tap fleet cleanup audit (orchestrator → brew-ops)

Plain text → continues active thread, or starts fresh.
EOF
)"
}

cmd_threads() {
  refresh_known_threads
  local active=$(get_active_thread)
  if [ ! -s "$KNOWN_THREADS_FILE" ]; then
    send_tg "<i>No threads yet. Send a request to start one.</i>"
    return
  fi
  local lines=()
  while IFS='|' read -r id title status opened; do
    [ -z "$id" ] && continue
    [ "$status" = "closed" ] && continue
    local marker="[ ]"
    [ "$id" = "$active" ] && marker="[✓]"
    local age=$(node -e "const o=new Date('$opened');const m=Math.floor((Date.now()-o)/60000);console.log(m<60?m+'m':m<1440?Math.floor(m/60)+'h':Math.floor(m/1440)+'d')" 2>/dev/null || echo "?")
    lines+=("$(printf '%s #%-4s %-50s %s ago' "$marker" "$id" "$(echo "$title" | head -c 48 | html_escape)" "$age")")
  done < "$KNOWN_THREADS_FILE"
  if [ ${#lines[@]} -eq 0 ]; then
    send_tg "<i>No open parent threads.</i>"
    return
  fi
  local body=""
  for l in "${lines[@]}"; do body="$body$l"$'\n'; done
  send_tg "<b>Open parent threads:</b>
<pre>$body</pre>
Plain text continues the active thread. <code>/use N</code> to switch."
}

cmd_use() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then send_tg "❌ <code>/use &lt;N&gt;</code> needs a thread id"; return; fi
  if ! grep -q "^${n}|" "$KNOWN_THREADS_FILE"; then send_tg "❌ thread #$n not in known-threads. <code>/threads</code> to list."; return; fi
  set_active_thread "$n"
  local title=$(grep "^${n}|" "$KNOWN_THREADS_FILE" | head -1 | cut -d'|' -f2 | html_escape)
  send_tg "✓ active → #$n ($title)"
}

cmd_new() {
  clear_active_thread
  send_tg "✓ active cleared. Next message starts a fresh request."
}

cmd_peek() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then send_tg "❌ <code>/peek &lt;N&gt;</code> needs a thread id"; return; fi
  local resp=$(curl -sf "$ORACLE_API/forum/thread/$n" 2>/dev/null)
  local count=$(echo "$resp" | jq -r '.thread.message_count // 0' 2>/dev/null)
  [ "$count" = "0" ] && { send_tg "❌ thread #$n empty or not found"; return; }
  local title=$(echo "$resp" | jq -r '.thread.title' 2>/dev/null | html_escape)
  local msgs=$(echo "$resp" | jq -r '.messages[-3:] | .[] | "[\(.id) \(.role)] \(.content[0:300])"' 2>/dev/null | html_escape)
  send_tg "<b>thread #$n</b> ($title)
<pre>$msgs</pre>"
}

cmd_close() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then send_tg "❌ <code>/close &lt;N&gt;</code> needs a thread id"; return; fi
  # Write a "close" envelope — orchestrator finalizes + posts closing message + status=closed
  local ts=$(date '+%Y-%m-%d_%H-%M')
  local path="$INBOX_DIR/${ts}_from-user_thread-${n}_close.md"
  {
    echo "---"
    echo "from: user"
    echo "to: orchestrator"
    echo "type: notify"
    echo "thread: $n"
    echo "subject: close: user-ratified close"
    echo "needs_response: false"
    echo "priority: normal"
    echo "created: $(date -Iseconds)"
    echo "source: telegram-chat-$CHAT"
    echo "user_action: close"
    echo "---"
    echo
    echo "User ratified close of thread #$n via Telegram."
  } > "$path"
  log "wrote close envelope for thread $n"
  send_tg "📨 close request sent for #$n. Orchestrator will post a closing summary + mark closed."
}

cmd_cancel() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then send_tg "❌ <code>/cancel &lt;N&gt;</code> needs a thread id"; return; fi
  local ts=$(date '+%Y-%m-%d_%H-%M')
  local path="$INBOX_DIR/${ts}_from-user_thread-${n}_cancel.md"
  {
    echo "---"
    echo "from: user"
    echo "to: orchestrator"
    echo "type: notify"
    echo "thread: $n"
    echo "subject: cancel: user-requested cancel"
    echo "needs_response: false"
    echo "priority: high"
    echo "created: $(date -Iseconds)"
    echo "source: telegram-chat-$CHAT"
    echo "user_action: cancel"
    echo "---"
    echo
    echo "User requested cancel of thread #$n via Telegram. Stop pending sub-tasks, post brief summary, mark closed."
  } > "$path"
  log "wrote cancel envelope for thread $n"
  send_tg "📨 cancel request sent for #$n. Orchestrator will stop pending work + close."
}

cmd_status() {
  local active=$(get_active_thread)
  refresh_known_threads
  local open_count=$(grep -v '|closed|' "$KNOWN_THREADS_FILE" 2>/dev/null | grep -c '^[0-9]' || echo 0)
  local stuck=$(grep -l 'failed_stuck\|failed_no_prompt' ~/.cache/inbox-watcher/state/*/*.state 2>/dev/null | wc -l | tr -d ' ')
  send_tg "<b>Status</b>
Active thread: ${active:-<i>none</i>}
Open parent threads: $open_count
Watcher failures: $stuck
<i>(use /threads, /escalations for detail)</i>"
}

cmd_escalations() {
  local found=$(grep -rln 'ESCALATE_TO_HUMAN' "$HOME/.arra-oracle-v2/ψ/" 2>/dev/null | head -10)
  if [ -z "$found" ]; then send_tg "<i>No escalation markers found in vault.</i>"; return; fi
  local body="$(echo "$found" | sed "s|$HOME/.arra-oracle-v2/||" | html_escape)"
  send_tg "<b>Escalation markers:</b>
<pre>$body</pre>"
}

# /cleanup — shortcut: dispatch to orchestrator → brew-ops to audit + propose
# fleet cleanup (stale claude sessions + worktrees). Mirrors what user typed
# manually as the first orchestrator dogfood; here it's a one-tap command.
cmd_cleanup() {
  local ts=$(date '+%Y-%m-%d_%H-%M')
  local path="$INBOX_DIR/${ts}_from-user_request.md"
  {
    echo "---"
    echo "from: user"
    echo "from_role: human"
    echo "to: orchestrator"
    echo "to_role: orchestrator"
    echo "type: consult"
    echo "subject: cleanup: audit + retire stale claude sessions and worktrees"
    echo "needs_response: true"
    echo "priority: normal"
    echo "created: $(date -Iseconds)"
    echo "source: telegram-chat-$CHAT"
    echo "user_action: cleanup-shortcut"
    echo "---"
    echo
    echo "# /cleanup shortcut"
    echo
    echo "Telegram one-tap fleet cleanup. Dispatch to brew-ops via the same shape the orchestrator already uses for fleet audits:"
    echo
    echo "1. Audit all worktrees + claude sessions (per repo) for stale candidates"
    echo "2. Classify into auto-safe / needs-review / lost-work groups"
    echo "3. brew-ops produces commands only — no execution"
    echo "4. Wait for /approve <group-id> per group"
    echo
    echo "Honor P-001 + AGENTS.md §9: never destructive without explicit user approval per group. brew-ops's worktree-janitor.sh dry-run output is a useful starting point."
  } > "$path"
  log "wrote /cleanup envelope"
  send_tg "🧹 cleanup audit dispatched. Orchestrator will fan out to brew-ops; expect a per-group proposal in ~2-3 min."
}

# ── update dispatcher ──────────────────────────────────────────────────────

handle_update() {
  local update="$1"
  local update_id=$(echo "$update" | jq -r '.update_id')
  local from_chat=$(echo "$update" | jq -r '.message.chat.id // empty')
  local text=$(echo "$update" | jq -r '.message.text // empty')

  echo "$update_id" > "$LAST_UPDATE_FILE"

  # Only respond to our designated chat
  [ "$from_chat" != "$CHAT" ] && { log "ignoring chat $from_chat (not $CHAT)"; return; }
  [ -z "$text" ] && return

  log "rx: $text"

  case "$text" in
    /help|/start)             cmd_help ;;
    /threads)                 cmd_threads ;;
    /use\ *)                  cmd_use "${text#/use }" ;;
    /new)                     cmd_new ;;
    /peek\ *)                 cmd_peek "${text#/peek }" ;;
    /close\ *)                cmd_close "${text#/close }" ;;
    /cancel\ *)               cmd_cancel "${text#/cancel }" ;;
    /status)                  cmd_status ;;
    /escalations)             cmd_escalations ;;
    /cleanup)                 cmd_cleanup ;;
    /*)                       send_tg "❓ unknown command. /help" ;;
    *)
      local active=$(get_active_thread)
      local path=$(write_envelope "$text" "$active")
      if [ -n "$active" ]; then
        send_tg "📨 continuation → thread #$active (orchestrator wakes within 60s)"
      else
        send_tg "📨 new request received (orchestrator will open a parent thread)"
      fi
      ;;
  esac
}

# ── long-poll loop ─────────────────────────────────────────────────────────

run_loop() {
  log "orchestrator-bot starting (chat=$CHAT, inbox=$INBOX_DIR)"
  local offset=0
  [ -f "$LAST_UPDATE_FILE" ] && offset=$(($(cat "$LAST_UPDATE_FILE") + 1))

  while true; do
    local resp
    resp=$(curl -sf -m 35 "https://api.telegram.org/bot${TOKEN}/getUpdates?timeout=30&offset=$offset" 2>&1)
    if ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
      log "getUpdates failed: $(echo "$resp" | head -c 200)"
      sleep 5
      continue
    fi
    local count=$(echo "$resp" | jq '.result | length')
    if [ "$count" -gt 0 ]; then
      for i in $(seq 0 $((count-1))); do
        local update=$(echo "$resp" | jq ".result[$i]")
        handle_update "$update"
        offset=$(($(echo "$update" | jq '.update_id') + 1))
      done
    fi
  done
}

case ${1:-loop} in
  loop|start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "already running: $(cat "$PID_FILE")" >&2
      exit 1
    fi
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; exit 0' INT TERM
    run_loop
    ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      local p=$(cat "$PID_FILE")
      kill -TERM "$p" 2>/dev/null && echo "stopped pid=$p" || echo "kill failed"
      rm -f "$PID_FILE"
    else
      echo "not running"
    fi
    ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "running: pid=$(cat "$PID_FILE")"
    else
      echo "stopped"
    fi
    echo "active thread: $(get_active_thread)"
    echo "known threads: $(wc -l < "$KNOWN_THREADS_FILE" 2>/dev/null || echo 0)"
    ;;
  test-send)
    send_tg "${2:-test from orchestrator-bot}"
    ;;
  *)
    cat <<USAGE >&2
usage: $0 {loop|start|stop|status|test-send <msg>}
USAGE
    exit 2
    ;;
esac

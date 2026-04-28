#!/usr/bin/env bash
# chat-watcher.sh — per-chat background watcher.
# Tails the chat's claude JSONL session file and pushes each new ASSISTANT
# text turn to Telegram as its own message — clean, no TUI box-drawing or
# scrollback noise.
#
# Spawned by bot.sh's cmd_chat / cmd_new / recover_watchers. Killed by
# cmd_end / cmd_close / cmd_watch off / when the pane dies.
#
# Args:
#   $1 — pane id (e.g. %33)
#   $2 — chat id (logical, e.g. pg-writer/practical-euclid)
#
# Tuning (env override):
#   POLL_INTERVAL          (default 2s) — how often we check JSONL for new lines
#
# State files:
#   $STATE_DIR/watch.<chat>.pid       — watcher pid
#   $STATE_DIR/last-user-send.<chat>  — bot.sh writes; watcher ignores
#                                       (kept for compatibility)

set -u
exec </dev/null

ENV_FILE=${ENV_FILE:-$HOME/.cache/brew-ops-bot/.env}
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a
TOKEN=${BREW_OPS_BOT_TOKEN:-}
CHAT=${BREW_OPS_BOT_CHAT:-}
[ -z "$TOKEN" ] || [ -z "$CHAT" ] && exit 1

PANE="${1:?pane id required}"
CHAT_ID="${2:?chat id required}"

STATE_DIR=${STATE_DIR:-$HOME/.cache/brew-ops-bot}
mkdir -p "$STATE_DIR"
LOG_FILE=$STATE_DIR/watcher.log
SAFE=$(echo "$CHAT_ID" | tr '/' '_')
PID_FILE=$STATE_DIR/watch.$SAFE.pid
# Persistent watch position so restarts don't lose responses written between
# prior shutdown and this startup. Format: <jsonl_path>|<line_count>
LINE_STATE_FILE=$STATE_DIR/last-line.$SAFE

POLL_INTERVAL=${POLL_INTERVAL:-2}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$CHAT_ID/$$] $*" >> "$LOG_FILE"; }

html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

send_tg() {
  local text="$1" disable_preview="${2:-false}"
  if [ ${#text} -gt 3900 ]; then text="${text:0:3850}

[…truncated]"; fi
  curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=$CHAT" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=$disable_preview" \
    --data-urlencode "text=$text" -o /dev/null 2>/dev/null
}

# ── Telegraph publishing ───────────────────────────────────────────────────
# Long messages get a sidecar telegra.ph page so they're readable on mobile
# (markdown tables, multi-column blocks, long code dumps). Telegram message
# carries a short preview + link to the full page.

TELEGRAPH_TOKEN_FILE=$STATE_DIR/telegraph-token
TELEGRAPH_THRESHOLD=${TELEGRAPH_THRESHOLD:-1500}

telegraph_token() {
  if [ -s "$TELEGRAPH_TOKEN_FILE" ]; then
    cat "$TELEGRAPH_TOKEN_FILE"
    return
  fi
  local resp tok
  resp=$(curl -sf "https://api.telegra.ph/createAccount?short_name=brew-ops-bot&author_name=brew-ops" 2>/dev/null)
  tok=$(echo "$resp" | jq -r '.result.access_token // empty' 2>/dev/null)
  if [ -n "$tok" ]; then
    echo "$tok" > "$TELEGRAPH_TOKEN_FILE"
    chmod 600 "$TELEGRAPH_TOKEN_FILE"
    echo "$tok"
  fi
}

# Publish text as a Telegraph page, echo URL on success, "" on failure.
# Wraps the content in a <pre> node so whitespace/tables/code are preserved.
telegraph_publish() {
  local title="$1" text="$2"
  local tok; tok=$(telegraph_token)
  [ -z "$tok" ] && return 1
  # Telegraph content schema: array of nodes. We use one <pre> node holding
  # the whole text — simple and preserves layout. Could split by \n\n into
  # <p> nodes for prose flow, but tables/code break under that.
  local content
  content=$(jq -nc --arg t "$text" '[{tag: "pre", children: [$t]}]') || return 1
  local resp
  resp=$(curl -sf "https://api.telegra.ph/createPage" \
    --data-urlencode "access_token=$tok" \
    --data-urlencode "title=$title" \
    --data-urlencode "author_name=brew-ops-bot" \
    --data-urlencode "content=$content" \
    --data-urlencode "return_content=false" 2>/dev/null)
  echo "$resp" | jq -r '.result.url // empty' 2>/dev/null
}

# Push an assistant text turn to Telegram. Decides:
#   short (< $TELEGRAPH_THRESHOLD chars) → inline <pre> in Telegram
#   long → telegraph page + Telegram preview with "📖 read full" link
push_turn() {
  local text="$1" chat_id="$2"
  local len=${#text}
  if [ "$len" -lt "$TELEGRAPH_THRESHOLD" ]; then
    send_tg "🔔 <b>$chat_id</b>:
<pre>$(echo "$text" | html_escape)</pre>"
    return
  fi
  # Long: try telegraph
  local title="$chat_id — $(date '+%Y-%m-%d %H:%M')"
  local url
  url=$(telegraph_publish "$title" "$text")
  if [ -n "$url" ]; then
    local preview; preview="${text:0:800}"
    send_tg "🔔 <b>$chat_id</b> (${len} chars):
<pre>$(echo "$preview" | html_escape)</pre>
…
📖 <a href=\"$url\">read full on web</a>"
  else
    # Fallback: send truncated inline (telegraph might be down/blocked)
    send_tg "🔔 <b>$chat_id</b>:
<pre>$(echo "$text" | html_escape)</pre>"
  fi
}

encode_cwd() { echo "$1" | sed 's|/|-|g; s|\.|-|g'; }

# Resolve the pane's current cwd → claude's projects dir for this worktree.
resolve_jsonl_dir() {
  local cwd
  cwd=$(tmux display-message -p -t "$PANE" "#{pane_current_path}" 2>/dev/null)
  [ -z "$cwd" ] && return 1
  local enc; enc=$(encode_cwd "$cwd")
  echo "$HOME/.claude/projects/$enc"
}

# Find newest .jsonl in the dir; "" if none yet.
latest_jsonl() {
  local dir="$1"
  [ ! -d "$dir" ] && return
  ls -t "$dir"/*.jsonl 2>/dev/null | head -1
}

# Extract assistant text content from one JSONL line; "" if not text-bearing.
extract_text() {
  jq -r 'select(.type == "assistant") |
    ((.message.content // "") |
      if type == "string" then .
      elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
      else "" end
    ) as $text |
    if ($text | length) > 0 then $text else empty end' 2>/dev/null
}

# write own pid for cmd_end / cmd_close to find
echo $$ > "$PID_FILE"
trap 'log "shutting down"; rm -f "$PID_FILE"; exit 0' INT TERM

log "starting (pane=$PANE)"

# Discover JSONL location. Wait up to 30s for it to exist (claude may take
# a moment to first-write after spawn).
JSONL_DIR=""
for _ in $(seq 1 15); do
  JSONL_DIR=$(resolve_jsonl_dir)
  [ -n "$JSONL_DIR" ] && [ -d "$JSONL_DIR" ] && break
  sleep 2
done

if [ -z "$JSONL_DIR" ] || [ ! -d "$JSONL_DIR" ]; then
  log "JSONL dir never appeared — bailing"
  rm -f "$PID_FILE"
  exit 1
fi
log "JSONL dir: $JSONL_DIR"

# Prime: prefer persistent state if it points to the current JSONL — this
# resumes after bot restart without losing claude responses that landed
# between shutdown and startup. Else fall back to current EOL (first run
# of this chat — don't replay full history).
current_jsonl=$(latest_jsonl "$JSONL_DIR")
last_line_count=0
if [ -n "$current_jsonl" ]; then
  if [ -s "$LINE_STATE_FILE" ]; then
    saved=$(cat "$LINE_STATE_FILE" 2>/dev/null)
    saved_path="${saved%|*}"
    saved_count="${saved##*|}"
    if [ "$saved_path" = "$current_jsonl" ] && [[ "$saved_count" =~ ^[0-9]+$ ]]; then
      last_line_count=$saved_count
      log "resumed from saved state: line $saved_count"
    else
      last_line_count=$(wc -l < "$current_jsonl" 2>/dev/null | tr -d ' ')
      log "saved state stale (path mismatch or invalid) — priming at EOL ($last_line_count)"
    fi
  else
    last_line_count=$(wc -l < "$current_jsonl" 2>/dev/null | tr -d ' ')
    log "primed at EOL ($last_line_count) — no saved state"
  fi
fi

while true; do
  # bail if pane is gone
  if ! tmux list-panes -a -F "#{pane_id}" 2>/dev/null | grep -q "^${PANE}\$"; then
    log "pane $PANE gone — exiting"
    break
  fi

  # Detect rotation: claude may start a new session file (e.g. on /clear).
  newest=$(latest_jsonl "$JSONL_DIR")
  if [ -z "$newest" ]; then
    sleep "$POLL_INTERVAL"; continue
  fi
  if [ "$newest" != "$current_jsonl" ]; then
    log "JSONL rotated: $current_jsonl → $newest"
    current_jsonl="$newest"
    last_line_count=0
  fi

  cur_count=$(wc -l < "$current_jsonl" 2>/dev/null | tr -d ' ')
  if [ "${cur_count:-0}" -gt "$last_line_count" ]; then
    # Read the new lines (between last_line_count+1 and cur_count) and push
    # each text-bearing assistant turn as its own Telegram message.
    sed -n "$((last_line_count + 1)),${cur_count}p" "$current_jsonl" 2>/dev/null \
      | while IFS= read -r line; do
        [ -z "$line" ] && continue
        local_text=$(echo "$line" | extract_text)
        [ -z "$local_text" ] && continue
        push_turn "$local_text" "$CHAT_ID"
        log "pushed assistant turn (${#local_text} chars)"
      done
    last_line_count=$cur_count
    # persist position so a bot restart doesn't lose unread turns
    echo "${current_jsonl}|${last_line_count}" > "$LINE_STATE_FILE"
  fi

  sleep "$POLL_INTERVAL"
done

rm -f "$PID_FILE"
log "exited"

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
#   POLL_INTERVAL          (default 2s)   — how often we check JSONL for new lines
#   JSONL_WAIT_SECONDS     (default 180s) — how long to wait for claude's first
#                          JSONL write before bailing. Bumped from 30s after
#                          chats with large CLAUDE.md kept missing the window
#                          and never recovered (no auto-respawn).
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
JSONL_WAIT_SECONDS=${JSONL_WAIT_SECONDS:-180}

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

# ── Gist publishing ────────────────────────────────────────────────────────
# Long messages get a sidecar secret Gist so markdown tables, code fences,
# and long code dumps render properly on mobile. Telegram message carries a
# short preview + link to the gist. Replaces an earlier telegra.ph path that
# bucketed everything into a single <pre> node — Telegraph's narrow column
# + pre-wrap squashed wide tables; GitHub renders Markdown tables natively.

GIST_THRESHOLD=${GIST_THRESHOLD:-1500}

# Publish text as a secret Gist; echo URL on success, "" on failure.
# Saved as .md so GitHub renders tables, fenced code, headings, etc.
gist_publish() {
  local title="$1" text="$2"
  command -v gh >/dev/null 2>&1 || return 1
  local safe; safe=$(echo "$title" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-')
  [ -z "$safe" ] && safe="brew-ops"
  local out url
  out=$(printf '%s' "$text" | gh gist create --filename "${safe}.md" --desc "$title" - 2>/dev/null)
  url=$(echo "$out" | grep -Eo 'https://gist\.github\.com/[^[:space:]]+' | tail -1)
  [ -n "$url" ] && echo "$url"
}

# Reverse-lookup alias for a chat_id (role/slug → alias name)
chat_alias_label() {
  local chat_id="$1"
  local f="$STATE_DIR/aliases"
  [ -f "$f" ] || return
  local al; al=$(grep -m1 "=${chat_id}$" "$f" | cut -d'=' -f1)
  [ -n "$al" ] && echo " ($al)"
}

# Push an assistant text turn to Telegram. Decides:
#   short (< $GIST_THRESHOLD chars) → inline <pre> in Telegram
#   long → secret gist + Telegram preview with "📖 read full" link
push_turn() {
  local text="$1" chat_id="$2"
  local alias_label; alias_label=$(chat_alias_label "$chat_id")
  local header="🔔 <b>${chat_id}${alias_label}</b>"
  local len=${#text}
  if [ "$len" -lt "$GIST_THRESHOLD" ]; then
    send_tg "${header}:
<pre>$(echo "$text" | html_escape)</pre>"
    return
  fi
  local title="${chat_id}${alias_label} — $(date '+%Y-%m-%d %H:%M')"
  local url
  url=$(gist_publish "$title" "$text")
  if [ -n "$url" ]; then
    local preview; preview="${text:0:800}"
    send_tg "${header} (${len} chars):
<pre>$(echo "$preview" | html_escape)</pre>
…
📖 <a href=\"$url\">read full on gist</a>"
  else
    send_tg "${header}:
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

# Discover JSONL location. Wait up to JSONL_WAIT_SECONDS for it to exist
# (claude with a large CLAUDE.md can take >30s before its first JSONL write).
JSONL_DIR=""
jsonl_attempts=$(( JSONL_WAIT_SECONDS / POLL_INTERVAL ))
[ "$jsonl_attempts" -lt 1 ] && jsonl_attempts=1
for _ in $(seq 1 "$jsonl_attempts"); do
  JSONL_DIR=$(resolve_jsonl_dir)
  [ -n "$JSONL_DIR" ] && [ -d "$JSONL_DIR" ] && break
  sleep "$POLL_INTERVAL"
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

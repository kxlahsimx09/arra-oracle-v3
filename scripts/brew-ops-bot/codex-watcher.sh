#!/usr/bin/env bash
# codex-watcher.sh — per-chat background watcher for Codex CLI.
# Tails Codex rollout JSONL and pushes each new assistant message turn to
# Telegram as a separate message.
#
# Args:
#   $1 — tmux pane id (e.g. %33)
#   $2 — chat id (logical, e.g. pg-writer/practical-euclid)
#
# State files:
#   $STATE_DIR/watch.<chat>.pid         — watcher pid
#   $STATE_DIR/last-codex-line.<chat>   — "<jsonl_path>|<line_count>"

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
LOG_FILE=$STATE_DIR/codex-watcher.log
SAFE=$(echo "$CHAT_ID" | tr '/' '_')
PID_FILE=$STATE_DIR/watch.$SAFE.pid
LINE_STATE_FILE=$STATE_DIR/last-codex-line.$SAFE

POLL_INTERVAL=${POLL_INTERVAL:-2}
JSONL_WAIT_SECONDS=${JSONL_WAIT_SECONDS:-180}
SESSION_SCAN_LIMIT=${SESSION_SCAN_LIMIT:-300}
IDLE_PROMPT_SECONDS=${IDLE_PROMPT_SECONDS:-30}
CODEX_SESSIONS_DIR=${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}

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

SCRIPT_DIR_WATCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gist.sh
. "$SCRIPT_DIR_WATCHER/gist.sh"

chat_alias_label() {
  local chat_id="$1"
  local f="$STATE_DIR/aliases"
  [ -f "$f" ] || return
  local al; al=$(grep -m1 "=${chat_id}$" "$f" | cut -d'=' -f1)
  [ -n "$al" ] && echo " ($al)"
}

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

resolve_cwd() {
  tmux display-message -p -t "$PANE" "#{pane_current_path}" 2>/dev/null
}

file_cwd() {
  local file="$1"
  head -n 1 "$file" 2>/dev/null \
    | jq -r 'select(.type == "session_meta") | .payload.cwd // empty' 2>/dev/null
}

find_latest_codex_jsonl() {
  local cwd="$1" file candidate_cwd
  [ -d "$CODEX_SESSIONS_DIR" ] || return
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    candidate_cwd=$(file_cwd "$file")
    [ "$candidate_cwd" = "$cwd" ] && { echo "$file"; return; }
  done < <(find "$CODEX_SESSIONS_DIR" -name 'rollout-*.jsonl' -type f 2>/dev/null | sort -r | head -"$SESSION_SCAN_LIMIT")
}

extract_agent_text() {
  jq -r '
    select(.type == "event_msg" and .payload.type == "agent_message") |
    .payload.message // empty
  ' 2>/dev/null
}

echo $$ > "$PID_FILE"
trap 'log "shutting down"; rm -f "$PID_FILE"; exit 0' INT TERM

log "starting (pane=$PANE)"

initial_cwd=$(resolve_cwd)
[ -z "$initial_cwd" ] && { log "pane cwd unavailable — bailing"; rm -f "$PID_FILE"; exit 1; }

current_jsonl=""
attempts=$(( JSONL_WAIT_SECONDS / POLL_INTERVAL ))
[ "$attempts" -lt 1 ] && attempts=1
for _ in $(seq 1 "$attempts"); do
  current_jsonl=$(find_latest_codex_jsonl "$initial_cwd")
  [ -n "$current_jsonl" ] && break
  sleep "$POLL_INTERVAL"
done

if [ -z "$current_jsonl" ]; then
  log "no codex rollout found for cwd=$initial_cwd — bailing"
  rm -f "$PID_FILE"
  exit 1
fi
log "JSONL file: $current_jsonl"

last_line_count=0
if [ -s "$LINE_STATE_FILE" ]; then
  saved=$(cat "$LINE_STATE_FILE" 2>/dev/null)
  saved_path="${saved%|*}"
  saved_count="${saved##*|}"
  if [ "$saved_path" = "$current_jsonl" ] && [[ "$saved_count" =~ ^[0-9]+$ ]]; then
    last_line_count=$saved_count
    log "resumed from saved state: line $saved_count"
  else
    last_line_count=$(wc -l < "$current_jsonl" 2>/dev/null | tr -d ' ')
    log "saved state stale — priming at EOL ($last_line_count)"
  fi
else
  last_line_count=$(wc -l < "$current_jsonl" 2>/dev/null | tr -d ' ')
  log "primed at EOL ($last_line_count)"
fi

last_change_ts=$(date +%s)
idle_notified=0

while true; do
  if ! tmux list-panes -a -F "#{pane_id}" 2>/dev/null | grep -q "^${PANE}\$"; then
    log "pane $PANE gone — exiting"
    break
  fi

  cwd_now=$(resolve_cwd)
  [ -z "$cwd_now" ] && { sleep "$POLL_INTERVAL"; continue; }

  newest=$(find_latest_codex_jsonl "$cwd_now")
  if [ -z "$newest" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi
  if [ "$newest" != "$current_jsonl" ]; then
    log "JSONL rotated: $current_jsonl → $newest"
    current_jsonl="$newest"
    last_line_count=0
  fi

  cur_count=$(wc -l < "$current_jsonl" 2>/dev/null | tr -d ' ')
  if [ "${cur_count:-0}" -gt "$last_line_count" ]; then
    sed -n "$((last_line_count + 1)),${cur_count}p" "$current_jsonl" 2>/dev/null \
      | while IFS= read -r line; do
        [ -z "$line" ] && continue
        msg=$(echo "$line" | extract_agent_text)
        [ -z "$msg" ] && continue
        push_turn "$msg" "$CHAT_ID"
        log "pushed agent turn (${#msg} chars)"
      done
    last_line_count=$cur_count
    last_change_ts=$(date +%s)
    idle_notified=0
    echo "${current_jsonl}|${last_line_count}" > "$LINE_STATE_FILE"
  elif [ "$idle_notified" = "0" ] && \
       [ $(( $(date +%s) - last_change_ts )) -ge "$IDLE_PROMPT_SECONDS" ]; then
    pane_visible=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
    if printf '%s' "$pane_visible" | grep -qE '^[[:space:]]*❯ [0-9]+\.'; then
      pane_snap=$(tmux capture-pane -t "$PANE" -pS -1000 2>/dev/null)
      url=$(gist_publish "${CHAT_ID} idle codex prompt — $(date '+%Y-%m-%d %H:%M')" "$pane_snap" "txt")
      body=${url:+"📖 <a href=\"$url\">read full pane on gist</a>"}
      send_tg "🔔 <b>${CHAT_ID}$(chat_alias_label "$CHAT_ID")</b> รอคำตอบ (Codex prompt — Escape ออก หรือไปตอบใน pane):
${body:-<pre>$(printf '%s' "$pane_snap" | tail -20 | html_escape)</pre>}"
      idle_notified=1
      log "idle prompt detected — pushed alert (gist=${url:-fail})"
    fi
  fi

  sleep "$POLL_INTERVAL"
done

rm -f "$PID_FILE"
log "exited"

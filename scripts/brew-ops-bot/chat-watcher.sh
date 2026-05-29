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
#   JSONL_WAIT_SECONDS     (default 480s) — how long to wait for the engine's
#                          first JSONL write before bailing. Was 30s → 180s →
#                          480s (2026-05-26): a claude chat with a large
#                          CLAUDE.md wrote its first JSONL at +7min, past the
#                          180s window, so the watcher bailed and — with no
#                          auto-respawn — the chat went silent. bot.sh now also
#                          re-runs recover_watchers periodically
#                          (WATCHER_RECOVER_INTERVAL) as a backstop for any
#                          watcher that still bails.
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

# Single-owner lock per resolved JSONL path. Two chats whose panes share a cwd
# (e.g. `maw wake` placed a second oracle into an existing oracle's worktree)
# resolve to the SAME JSONL and would otherwise both relay every assistant turn
# — the user sees every message twice with two different chat tags. The lock
# file holds the PID of the watcher that owns this JSONL; rivals see it, find
# the owner alive, and exit cleanly. Filed by thread #260 with reproduction.
CLAIMED_LOCK=""
jsonl_lock_for(){ echo "$STATE_DIR/jsonl-owner.$(printf '%s' "$1"|shasum 2>/dev/null|cut -c1-16)"; }
claim_jsonl(){
  local jf="$1" lock owner
  [ -z "$jf" ] && return 0
  lock=$(jsonl_lock_for "$jf")
  if [ -f "$lock" ]; then
    owner=$(cat "$lock" 2>/dev/null)
    [ -n "$owner" ] && [ "$owner" != "$$" ] && kill -0 "$owner" 2>/dev/null && return 1
  fi
  echo "$$" >"$lock"
  CLAIMED_LOCK="$lock"
  return 0
}
release_jsonl(){
  [ -n "$CLAIMED_LOCK" ] && rm -f "$CLAIMED_LOCK"
  CLAIMED_LOCK=""
}

POLL_INTERVAL=${POLL_INTERVAL:-2}
JSONL_WAIT_SECONDS=${JSONL_WAIT_SECONDS:-480}
# Idle-prompt alert: JSONL quiet this long + pane shows claude's TUI
# selection cursor (`❯ `) → one-time Telegram nudge. Reset on next JSONL line.
IDLE_PROMPT_SECONDS=${IDLE_PROMPT_SECONDS:-30}

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

# Gist publishing — `gist_publish` + `GIST_THRESHOLD` live in `gist.sh`
# (sourced below) so bot.sh's cmd_look and this watcher stay in sync.
# Replaced an earlier telegra.ph path that bucketed everything into one
# <pre> node — Telegraph's narrow column + pre-wrap squashed wide tables;
# GitHub renders Markdown tables natively for assistant turns.
SCRIPT_DIR_WATCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gist.sh
. "$SCRIPT_DIR_WATCHER/gist.sh"

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

# Deterministic resolution of the JSONL for the claude session running in
# $PANE — fixes the "two oracles in same cwd → wrong sibling's JSONL"
# collision (#114 single-owner lock prevented the double-relay symptom but
# locked the loser out forever instead of giving it its own JSONL).
#
# Mechanism: claude 2.x writes a per-process mapping file at
#   ~/.claude/sessions/<pid>.json   (keyed by claude's own PID)
# whose `sessionId` field is the basename of THIS session's JSONL in $dir.
# We BFS the pane's foreground-process tree (root_pid + descendants),
# stop at the first PID that owns a sessions/<pid>.json, read its
# sessionId, and return `$dir/<sessionId>.jsonl`. Returns 1 (empty
# stdout) if the mapping can't be resolved — caller decides between
# waiting and the legacy `latest_jsonl` fallback.
resolve_pane_jsonl() {
  local pane="$1" dir="$2" root_pid sid pid kid
  root_pid=$(tmux display-message -p -t "$pane" "#{pane_pid}" 2>/dev/null)
  [ -z "$root_pid" ] && return 1
  local -a queue=("$root_pid")
  local seen=" $root_pid "
  while [ "${#queue[@]}" -gt 0 ]; do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    if [ -f "$HOME/.claude/sessions/$pid.json" ]; then
      sid=$(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$pid.json" 2>/dev/null)
      if [ -n "$sid" ]; then
        echo "$dir/$sid.jsonl"
        return 0
      fi
    fi
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
      case "$seen" in *" $kid "*) continue ;; esac
      seen="$seen$kid "
      queue+=("$kid")
    done
  done
  return 1
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
trap 'log "shutting down"; release_jsonl; rm -f "$PID_FILE"; exit 0' INT TERM

log "starting (pane=$PANE)"

# Discover JSONL location. Wait up to JSONL_WAIT_SECONDS for both the dir
# (claude with a large CLAUDE.md can take >30s before its first JSONL write)
# AND the specific session file for THIS pane to appear. Waiting for the
# pane-specific file matters when sibling oracles share the cwd: picking
# `latest_jsonl` early would grab the sibling's file and the lock would
# exit us out permanently (the original orchestrator/oracle bug).
JSONL_DIR=""
current_jsonl=""
jsonl_attempts=$(( JSONL_WAIT_SECONDS / POLL_INTERVAL ))
[ "$jsonl_attempts" -lt 1 ] && jsonl_attempts=1
for _ in $(seq 1 "$jsonl_attempts"); do
  if [ -z "$JSONL_DIR" ] || [ ! -d "$JSONL_DIR" ]; then
    JSONL_DIR=$(resolve_jsonl_dir)
  fi
  if [ -n "$JSONL_DIR" ] && [ -d "$JSONL_DIR" ]; then
    current_jsonl=$(resolve_pane_jsonl "$PANE" "$JSONL_DIR")
    [ -n "$current_jsonl" ] && [ -f "$current_jsonl" ] && break
  fi
  sleep "$POLL_INTERVAL"
done

if [ -z "$JSONL_DIR" ] || [ ! -d "$JSONL_DIR" ]; then
  log "JSONL dir never appeared — bailing"
  rm -f "$PID_FILE"
  exit 1
fi
log "JSONL dir: $JSONL_DIR"

# Fallback to legacy newest-in-dir when pane-specific resolution never
# yielded a real file within the wait window — preserves pre-fix behaviour
# for non-claude engines (codex) and edge cases where the sessions/<pid>.json
# mapping isn't available. The single-owner lock still prevents double-relay.
if [ -z "$current_jsonl" ] || [ ! -f "$current_jsonl" ]; then
  current_jsonl=$(latest_jsonl "$JSONL_DIR")
  [ -n "$current_jsonl" ] && log "pane-specific JSONL unresolved within ${JSONL_WAIT_SECONDS}s — fell back to legacy newest-in-dir: $current_jsonl"
fi

# Prime: prefer persistent state if it points to the current JSONL — this
# resumes after bot restart without losing claude responses that landed
# between shutdown and startup. Else fall back to current EOL (first run
# of this chat — don't replay full history).
# Acquire single-owner lock on the resolved JSONL. If another live watcher
# already owns it (same-cwd collision), exit before we duplicate every relay.
if [ -n "$current_jsonl" ] && ! claim_jsonl "$current_jsonl"; then
  log "JSONL $current_jsonl already owned by a live watcher — exiting (avoid double-relay)"
  rm -f "$PID_FILE"
  exit 0
fi
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

last_change_ts=$(date +%s)
idle_notified=0

while true; do
  # bail if pane is gone
  if ! tmux list-panes -a -F "#{pane_id}" 2>/dev/null | grep -q "^${PANE}\$"; then
    log "pane $PANE gone — exiting"
    break
  fi

  # Detect rotation: claude may start a new session file (e.g. on /clear)
  # which updates THIS pane's sessions/<pid>.json with a new sessionId.
  # Pane-aware lookup keeps sibling oracles creating new sessions in the
  # same cwd from triggering a false rotation here (the legacy
  # `latest_jsonl` would have flapped to the sibling's file).
  newest=$(resolve_pane_jsonl "$PANE" "$JSONL_DIR")
  if [ -n "$newest" ] && [ "$newest" != "$current_jsonl" ]; then
    log "JSONL rotated: ${current_jsonl:-(none)} → $newest"
    current_jsonl="$newest"
    last_line_count=0
    # Re-acquire the lock for the rotated file. Release the old one first so a
    # successor can pick it up, then try to claim the new one. If a peer already
    # owns the new JSONL, exit — the same-cwd-double-relay guard applies here too.
    release_jsonl
    if ! claim_jsonl "$current_jsonl"; then
      log "rotated JSONL $current_jsonl owned by another watcher — exiting"
      rm -f "$PID_FILE"
      break
    fi
  fi
  # Nothing to tail yet (cold start, mapping not readable, or file not
  # written) — keep waiting; the rotation block above will pick it up the
  # moment pane-aware resolution + file existence both succeed.
  if [ -z "$current_jsonl" ] || [ ! -f "$current_jsonl" ]; then
    sleep "$POLL_INTERVAL"; continue
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
    last_change_ts=$(date +%s)
    idle_notified=0
    # persist position so a bot restart doesn't lose unread turns
    echo "${current_jsonl}|${last_line_count}" > "$LINE_STATE_FILE"
  elif [ "$idle_notified" = "0" ] && \
       [ $(( $(date +%s) - last_change_ts )) -ge "$IDLE_PROMPT_SECONDS" ]; then
    # JSONL quiet — match only `❯ N.` (numbered menu) on visible pane.
    # Bare `❯ ` is claude's text-input prefix → false-positive while streaming.
    pane_visible=$(tmux capture-pane -t "$PANE" -p 2>/dev/null)
    if printf '%s' "$pane_visible" | grep -qE '^[[:space:]]*❯ [0-9]+\.'; then
      pane_snap=$(tmux capture-pane -t "$PANE" -pS -1000 2>/dev/null)
      url=$(gist_publish "${CHAT_ID} idle TUI prompt — $(date '+%Y-%m-%d %H:%M')" "$pane_snap" "txt")
      body=${url:+"📖 <a href=\"$url\">read full pane on gist</a>"}
      send_tg "🔔 <b>${CHAT_ID}$(chat_alias_label "$CHAT_ID")</b> รอคำตอบ (TUI prompt — Escape ออก หรือไปตอบใน pane):
${body:-<pre>$(printf '%s' "$pane_snap" | tail -20 | html_escape)</pre>}"
      idle_notified=1
      log "idle TUI prompt detected — pushed alert (gist=${url:-fail})"
    fi
  fi

  sleep "$POLL_INTERVAL"
done

rm -f "$PID_FILE"
log "exited"

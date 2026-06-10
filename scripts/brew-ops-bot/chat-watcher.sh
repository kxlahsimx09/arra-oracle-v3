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
# AskUserQuestion forwarding: ASK_LAST dedups (push once per tool_use id);
# ASK_PENDING tells bot.sh a menu is live (format "<tool_id>|<n_questions>") so a
# "2,2" text reply can be routed to TUI-driving instead of the agent's input.
ASK_LAST_STATE=$STATE_DIR/ask-last.$SAFE
ASK_PENDING_STATE=$STATE_DIR/ask-pending.$SAFE
# Cross-line keepalive flag: set when the last JSONL line was an agent-teams
# idle_notification ping, so the NEXT assistant turn (its throwaway reply) is
# suppressed. A file because the push loop runs in a pipe subshell that can't
# mutate parent shell vars. Reset at startup.
KEEPALIVE_STATE=$STATE_DIR/keepalive.$SAFE
: > "$KEEPALIVE_STATE"
# Idle-run counter + re-alert cooldown. A teammate that finished its work but
# whose session isn't shut down answers each agent-teams idle ping with a
# throwaway turn, forever. After IDLE_ALERT_THRESHOLD consecutive idle replies
# we alert the orchestrator/human so they can decide whether to close the
# campaign — we never close it ourselves (the teammate may yet get a follow-up).
# The alert is rate-limited by IDLE_REALERT_COOLDOWN (a persisted timestamp),
# NOT one-shot: a passive orchestrator poke ("STAND BY") is a real user turn, so
# it resets IDLE_COUNT and re-arms the counter — a one-shot flag therefore
# re-fired forever. With a cooldown we send at most one alert per campaign per
# window, regardless of how often the counter re-arms; a genuinely-new idle
# spell after the cooldown still alerts. IDLE_COUNT/IDLE_ALERTED reset when real
# work resumes; IDLE_ALERTED_TS does NOT (it gates the cooldown and must survive
# both user turns and watcher restarts). Files (pipe-subshell safe).
IDLE_COUNT_STATE=$STATE_DIR/idle-count.$SAFE
IDLE_ALERTED_STATE=$STATE_DIR/idle-alerted.$SAFE
# Last-alert timestamp (epoch). NOT truncated at startup: a watcher restart must
# not be able to re-arm the alarm by clearing the cooldown.
IDLE_ALERTED_TS_STATE=$STATE_DIR/idle-alerted-ts.$SAFE
: > "$IDLE_COUNT_STATE"
: > "$IDLE_ALERTED_STATE"
IDLE_ALERT_THRESHOLD=${IDLE_ALERT_THRESHOLD:-10}
IDLE_REALERT_COOLDOWN=${IDLE_REALERT_COOLDOWN:-21600}  # 6h default

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
  local text="$1" disable_preview="${2:-false}" markup="${3:-}"
  if [ ${#text} -gt 3900 ]; then text="${text:0:3850}

[…truncated]"; fi
  local args=(
    --data-urlencode "chat_id=$CHAT"
    --data-urlencode "parse_mode=HTML"
    --data-urlencode "disable_web_page_preview=$disable_preview"
    --data-urlencode "text=$text"
  )
  # Optional inline keyboard (reply_markup JSON) — used by the TUI-menu push so
  # the user can pick a `❯ N.` option from Telegram instead of driving the pane.
  [ -n "$markup" ] && args+=(--data-urlencode "reply_markup=$markup")
  curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    "${args[@]}" -o /dev/null 2>/dev/null
}

# Remote-control keyboard for a live TUI menu. Each button → bot.sh's nav:
# handler, which sends the key to the pane, re-captures, and edits the message.
# Identical layout is rebuilt in bot.sh (nav_keyboard) for the edits.
menu_remote_kbd() {
  local c="$CHAT_ID"
  printf '{"inline_keyboard":[[{"text":"⬆️","callback_data":"nav:%s:up"},{"text":"⬇️","callback_data":"nav:%s:down"}],[{"text":"✅ เลือก/toggle","callback_data":"nav:%s:enter"}],[{"text":"📤 Submit","callback_data":"nav:%s:submit"},{"text":"❌ Esc","callback_data":"nav:%s:esc"}]]}' "$c" "$c" "$c" "$c" "$c"
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

# A streamed JSONL line carrying an AskUserQuestion tool_use → push the full
# questions + options to Telegram with one inline button per option. Reading the
# structured tool input is reliable even when the on-screen TUI is scrolled or
# stale (capture-pane can only see what fits). Fires once per tool_use id. The
# button callback "ask:<chat>:<qi>:<oi>" is driven by bot.sh's cmd_ask; we also
# stamp ASK_PENDING so a plain "2,2" text reply can be routed to driving.
# Returns 0 (caller should `continue`) when it handled an AskUserQuestion line.
maybe_push_ask() {
  local line="$1" payload id nq body kbd
  payload=$(printf '%s' "$line" | jq -c '[.. | objects | select(.type?=="tool_use" and .name?=="AskUserQuestion")] | last // empty' 2>/dev/null)
  [ -z "$payload" ] && return 1
  id=$(printf '%s' "$payload" | jq -r '.id // empty')
  [ -z "$id" ] && return 1
  [ "$id" = "$(cat "$ASK_LAST_STATE" 2>/dev/null)" ] && return 0   # already pushed
  echo "$id" > "$ASK_LAST_STATE"
  nq=$(printf '%s' "$payload" | jq -r '.input.questions | length')
  printf '%s|%s' "$id" "$nq" > "$ASK_PENDING_STATE"
  # HTML-escape the user-facing labels (option text can contain & < >).
  body=$(printf '%s' "$payload" | jq -r '
    def esc: gsub("&";"&amp;")|gsub("<";"&lt;")|gsub(">";"&gt;");
    .input.questions | to_entries | map(
      "❓ <b>Q\(.key+1). \(.value.header|esc)</b> — \(.value.question|esc)\n" +
      (.value.options | to_entries | map("   \(.key+1). \(.value.label|esc)") | join("\n"))
    ) | join("\n\n")')
  kbd=$(printf '%s' "$payload" | jq -c --arg chat "$CHAT_ID" \
    '{inline_keyboard: (.input.questions | to_entries | map(.key as $qi | .value.options | to_entries | map({text: "Q\($qi+1)·\(.key+1)", callback_data: "ask:\($chat):\($qi):\(.key)"})))}')
  send_tg "🔔 <b>${CHAT_ID}$(chat_alias_label "$CHAT_ID")</b> ขอให้เลือก (AskUserQuestion):

${body}

กดปุ่ม <b>Q·ข้อ</b> ตอบแต่ละคำถาม หรือพิมพ์ตอบรวมเป็น <code>$(printf '%s' "$payload" | jq -r '[.input.questions[]|"1"]|join(",")')</code>" false "$kbd"
  log "AskUserQuestion pushed (${nq} questions, id=$id)"
  return 0
}

# Resolve the owning orchestrator's tmux pane for the teammate in $PANE (§151).
# Chain: teammate pane_pid → its `claude` proc's --system-prompt-file → that
# path embeds the orchestrator's worktree (…/<orch-wt>/ψ/memory/mailbox/teams/…)
# → the tmux pane whose cwd == that worktree. This binds the alert to the
# orchestrator that ACTUALLY spawned this teammate, so it never misfires across
# concurrent orchestrators (§181). Empty stdout if it can't be resolved.
# Used instead of the team leader-inbox: that inbox is not polled by an
# interactive orchestrator session (verified 2026-05-31 — a message written to
# inboxes/leader.json stayed read:false and never reached the conversation; the
# orchestrator monitors teammates via tmux capture-pane, not inbox files).
resolve_owner_pane() {
  local tpid spf owt p c
  tpid=$(tmux display-message -p -t "$PANE" "#{pane_pid}" 2>/dev/null)
  [ -z "$tpid" ] && return 1
  # BFS the pane's process subtree for the claude proc carrying --system-prompt-file
  local -a q=("$tpid"); local seen=" $tpid "
  while [ "${#q[@]}" -gt 0 ]; do
    p="${q[0]}"; q=("${q[@]:1}")
    c=$(ps -o command= -p "$p" 2>/dev/null)
    case "$c" in
      *--system-prompt-file*)
        spf=$(printf '%s' "$c" | grep -oE -- '--system-prompt-file [^ ]+' | awk '{print $2}')
        break ;;
    esac
    local kid
    for kid in $(pgrep -P "$p" 2>/dev/null); do
      case "$seen" in *" $kid "*) continue ;; esac
      seen="$seen$kid "; q+=("$kid")
    done
  done
  [ -z "${spf:-}" ] && return 1
  owt=${spf%%/ψ/*}                       # orchestrator worktree
  [ "$owt" = "$spf" ] && return 1        # path didn't contain /ψ/ — bail
  tmux list-panes -a -F '#{pane_id} #{pane_current_path}' 2>/dev/null \
    | awk -v w="$owt" '$2==w {print $1; exit}'
}

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

# Classify one JSONL line for keepalive filtering (agent-teams):
#   "ping" — a user turn that is an agent-teams idle/keepalive notification
#            (content carries `idle_notification`). Polls the teammate when it
#            has no work; the teammate answers with throwaway status turns
#            ("Idle.", "Standing by.", "รออยู่", … — any words, possibly several
#            assistant turns per single ping).
#   "user" — a REAL user turn (a genuine task / teammate-message with content,
#            NOT an idle_notification). This is the signal that work resumed.
#   "asst" — an assistant turn (candidate to push)
#   ""     — anything else (system, attachments, settings, etc.)
# Structural, NOT word-based: once a ping is seen we enter "idle mode" and drop
# EVERY assistant turn (an idle ping can draw 2–3 "Idle." turns) until a real
# user turn proves work resumed. We key on the trigger, never the words.
classify_line() {
  jq -r '
    if .type == "user"
       and ((.message.content // "") | tostring | test("idle_notification"))
    then "ping"
    elif .type == "user" then "user"
    elif .type == "assistant" then "asst"
    else "" end' 2>/dev/null
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
        # NB: TUI selection menus are handled by the screen-scrape remote-control
        # path in the idle block below, NOT from JSONL — in agent-teams the
        # JSONL↔on-screen mapping is unreliable (different sessions share a
        # project dir), so the live pane is the ground truth.
        # Keepalive filter (agent-teams): an idle_notification user turn polls
        # the teammate; the teammate's reply to it is throwaway status noise.
        # Suppress that reply by keying on the trigger, not the words. State
        # carries across lines via $KEEPALIVE_STATE (the subshell from the pipe
        # can't mutate parent vars, so we persist the flag to a file).
        kind=$(echo "$line" | classify_line)
        # Idle-mode latch: a ping turns it ON; a REAL user turn (work resumed)
        # turns it OFF. While ON, drop EVERY assistant turn — a single idle ping
        # can draw several "Idle." replies, so clearing on the first reply (the
        # earlier bug) let the 2nd/3rd leak. Only a genuine user turn re-opens
        # the push gate.
        case "$kind" in
          ping) echo 1 > "$KEEPALIVE_STATE"; continue ;;
          user)  # A user turn ARRIVED — re-open the push gate so the reply is
            # processed. But a user turn arriving is NOT proof that work
            # resumed: a PASSIVE orchestrator poke ("stand by / no action
            # needed", keepalive nudges) is a non-ping user turn too. Resetting
            # idle tracking here re-armed the alarm on a parked teammate, so the
            # next idle ping re-fired the alert (the re-alert loop #120 only
            # mitigated). Idle tracking is now reset solely by GENUINE assistant
            # work — see the reset below, on the push path.
            : > "$KEEPALIVE_STATE" ;;
        esac
        local_text=$(echo "$line" | extract_text)
        [ -z "$local_text" ] && continue
        if [ "$kind" = "asst" ] && [ "$(cat "$KEEPALIVE_STATE" 2>/dev/null)" = "1" ]; then
          log "suppressed idle-mode assistant turn (${#local_text} chars): ${local_text:0:40}"
          # Count consecutive idle replies; one-shot alert at the threshold so the
          # orchestrator can decide to close (we never close it ourselves).
          ic=$(( $(cat "$IDLE_COUNT_STATE" 2>/dev/null || echo 0) + 1 ))
          echo "$ic" > "$IDLE_COUNT_STATE"
          now=$(date +%s)
          last_alert=$(cat "$IDLE_ALERTED_TS_STATE" 2>/dev/null || echo 0)
          [[ "$last_alert" =~ ^[0-9]+$ ]] || last_alert=0
          if [ "$ic" -ge "$IDLE_ALERT_THRESHOLD" ] && \
             [ $(( now - last_alert )) -ge "$IDLE_REALERT_COOLDOWN" ]; then
            echo "$now" > "$IDLE_ALERTED_TS_STATE"
            echo 1 > "$IDLE_ALERTED_STATE"   # keep for logging/compat
            # Notify the OWNING orchestrator directly in its conversation — the
            # same send-keys channel the kickoff uses, which we know it reads.
            # We never close the campaign ourselves; the orchestrator decides.
            slug=${CHAT_ID#*/}
            alert_msg="⏸ teammate [${CHAT_ID}] looks idle/done — it has answered ${ic} keepalive pings with no new work. If its campaign is finished, close it: team-dispatch-finish.sh --campaign ${slug} — otherwise send it the next task. (auto-detected by chat-watcher; nothing was closed)"
            owner_pane=$(resolve_owner_pane)
            if [ -n "$owner_pane" ]; then
              # Bracketed-paste-safe: literal text via -l, settle, Enter separately.
              tmux send-keys -t "$owner_pane" -l "$alert_msg" 2>/dev/null
              sleep 0.4
              tmux send-keys -t "$owner_pane" Enter 2>/dev/null
              log "idle-alert → owner pane $owner_pane via send-keys (${ic} idle replies)"
            else
              # Owner pane unresolved (orchestrator pane closed / cwd mismatch) —
              # fall back to Telegram so the alert is never silently dropped.
              send_tg "⏸ <b>${CHAT_ID}$(chat_alias_label "$CHAT_ID")</b> idle ×${ic} — teammate looks done; owner orchestrator pane not resolved. Close via <code>team-dispatch-finish.sh --campaign ${slug}</code> or send it a task. (notify-only — not auto-closed)"
              log "idle-alert owner pane unresolved → telegram fallback (${ic} idle replies)"
            fi
          fi
          continue
        fi
        # GENUINE WORK RESUMED — the true reset signal. We only get here for an
        # assistant turn when KEEPALIVE != 1 (idle-mode asst turns were
        # suppressed + `continue`d above), so a substantive asst turn means the
        # teammate is actually working again, not echoing a poke. Guard on
        # length so a stray short throwaway ("Idle.", "รออยู่") can't reset the
        # counter. This — not mere user-turn arrival — clears idle tracking.
        if [ "$kind" = "asst" ] && [ "${#local_text}" -gt 16 ]; then
          : > "$IDLE_COUNT_STATE"
          : > "$IDLE_ALERTED_STATE"
        fi
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
      # A TUI selection menu is up. Push the live screen + a remote-control
      # keyboard (⬆️⬇️ ✅ 📤 ❌). The user drives the pane from chat; bot.sh's
      # nav: handler sends each key, re-captures, and edits this message so the
      # cursor/checkboxes update live. Works for single- AND multi-select
      # (checkbox + Submit) menus — the on-screen pane is the ground truth.
      menu_snap=$(printf '%s' "$pane_visible" | grep -vE '^[[:space:]]*$' | tail -22 | html_escape)
      send_tg "🎮 <b>${CHAT_ID}$(chat_alias_label "$CHAT_ID")</b> เมนู TUI — คุมด้วยปุ่มล่าง (✅ เลือก/ติ๊ก, 📤 ไป Submit):
<pre>${menu_snap}</pre>" false "$(menu_remote_kbd)"
      idle_notified=1
      log "TUI menu detected — pushed remote-control keyboard"
    fi
  fi

  sleep "$POLL_INTERVAL"
done

rm -f "$PID_FILE"
log "exited"

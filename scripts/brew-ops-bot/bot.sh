#!/usr/bin/env bash

# --- portability shim (BSD/GNU): file mtime as epoch. GNU-first (-c %Y) so Linux
# works; BSD (-f %m) fallback for macOS. (BSD-first is buggy on Linux: stat -f
# means --file-system there and emits garbage before any fallback.)
_mtime() { stat -c %Y "$@" 2>/dev/null || _mtime "$@" 2>/dev/null; }
# brew-ops-bot.sh — Telegram bot for Soul-Brews ops awareness + claude orchestrator.
#
# Phases:
#   1 read-only:   /help /blockers /pending /threads
#   2 raw tmux:    /list  (pane-id view, kept for power use)
#   3a chat mgmt:  /roles /chats /chat /new /close
#   3b history:    /look [N|full] /history [target N] /retro [role N] /closed
#   4 reserved:    plain-message conversation auto-reply loop
#
# Plain text → routes to current chat (set by /chat).

set -u
exec </dev/null

ENV_FILE=${ENV_FILE:-$HOME/.cache/brew-ops-bot/.env}
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

TOKEN=${BREW_OPS_BOT_TOKEN:-}
CHAT=${BREW_OPS_BOT_CHAT:-}
[ -z "$TOKEN" ] || [ -z "$CHAT" ] && { echo "ERR: env missing in $ENV_FILE" >&2; exit 1; }

STATE_DIR=${STATE_DIR:-$HOME/.cache/brew-ops-bot}
mkdir -p "$STATE_DIR"
LOG_FILE=${LOG_FILE:-$STATE_DIR/bot.log}
PID_FILE=${PID_FILE:-$STATE_DIR/bot.pid}
AUDIT_FILE=$STATE_DIR/audit.log
LAST_UPDATE_ID_FILE=$STATE_DIR/last-update-id
ACTIVE_CHAT_FILE_PREFIX=$STATE_DIR/active-chat
# How often (seconds) the main loop re-runs recover_watchers to respawn any
# chat-watcher that bailed mid-session (e.g. an engine cold-start that exceeded
# chat-watcher.sh's JSONL_WAIT_SECONDS). The startup recover_watchers runs only
# once, so without this a bailed watcher stayed dead until a bot restart or a
# manual /watch all. Set 0 to disable the periodic sweep.
WATCHER_RECOVER_INTERVAL=${WATCHER_RECOVER_INTERVAL:-300}

# Repos in scope for blockers/pending markers + orphan-worktree sweep.
# Populated at boot by load_roles from fleet configs — every repo with at
# least one fleet-registered role becomes scope-eligible. Adding a fleet
# json (user-level or .agent/fleet/) auto-extends scope; no code change.
REPOS=()
ORACLE_DB=$HOME/.arra-oracle-v2/oracle.db
SQLITE=$(command -v sqlite3 || echo /usr/bin/sqlite3)
RETRO_ROOT=$HOME/.arra-oracle-v2/ψ/memory/retrospectives

# Defined here (above their first top-level caller, load_roles) so bash
# resolves `log` to this function instead of falling through to PATH and
# hitting macOS /usr/bin/log. See helpers section below for siblings.
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
audit() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$AUDIT_FILE"; }

# Role registry — loaded dynamically from maw fleet configs at boot.
# Format per entry: <role>|<session>|<repo-path>|<default-engine>
# Sources scanned (in order; later entries override earlier ones by role name):
#   1. ~/.config/maw/fleet/*.json                         (user-level, primary)
#   2. ~/Code/github.com/<owner>/<repo>/.agent/fleet/*.json (project-local)
# Role name = window name with "-oracle" suffix stripped (e.g. "pg-writer-oracle"
# → "pg-writer"; "next-architect-oracle" → "next-architect").
ROLES=()
load_roles() {
  ROLES=()
  local seen=""
  local sources=()
  # 1. user-level maw fleet
  for f in "$HOME/.config/maw/fleet/"*.json; do
    [ -f "$f" ] && sources+=("$f")
  done
  # 2. project-local fleet in ghq repos. -L follows symlinks because .agent
  # is typically a symlink into mb_agent_oracle_memory vault.
  while IFS= read -r f; do
    [ -f "$f" ] && sources+=("$f")
  done < <(find -L "$HOME/Code/github.com" -maxdepth 5 -path "*.agent/fleet/*.json" 2>/dev/null | sort -u)
  for f in "${sources[@]}"; do
    local session
    session=$(jq -r '.name // empty' "$f" 2>/dev/null)
    [ -z "$session" ] && continue
    local repo_slug
    repo_slug=$(jq -r '.project_repos[0] // empty' "$f" 2>/dev/null)
    [ -z "$repo_slug" ] && continue
    local repo_path="$HOME/Code/github.com/$repo_slug"
    while IFS=$'\t' read -r win eng; do
      [ -z "$win" ] && continue
      local role="${win%-oracle}"
      # dedupe: only first occurrence wins
      case "|$seen|" in *"|$role|"*) continue ;; esac
      seen+="|$role"
      ROLES+=("${role}|${session}|${repo_path}|${eng}")
    done < <(jq -r '.windows[]? | [(.name // empty), (.engine // empty)] | @tsv' "$f" 2>/dev/null)
  done
  REPOS=()
  local seen_repo="" rp
  for line in "${ROLES[@]}"; do
    rp=$(echo "$line" | cut -d'|' -f3)
    [ -z "$rp" ] && continue
    case "|$seen_repo|" in *"|$rp|"*) continue ;; esac
    seen_repo+="|$rp"
    REPOS+=("$rp")
  done
  log "loaded ${#ROLES[@]} roles across ${#REPOS[@]} repos: $(echo "${ROLES[@]}" | tr ' ' '\n' | cut -d'|' -f1 | tr '\n' ' ')"
}
load_roles

# Shared gist helper — used by cmd_look as a fallback when a tmux capture
# would otherwise overflow Telegram's 4096-char message cap. Also used by
# chat-watcher.sh's auto-push, so threshold + publish behaviour live in one
# file and stay in sync.
SCRIPT_DIR_BOT_INIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gist.sh
. "$SCRIPT_DIR_BOT_INIT/gist.sh"

# ── helpers ────────────────────────────────────────────────────────────────

# log() / audit() are hoisted above load_roles (see top of file).

# HTML-escape dynamic content before embedding in send_tg's parse_mode=HTML.
html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

send_tg() {
  local text="$1" markup="${2:-}"
  # Last-resort truncation. Callers wrapping content in HTML tags should
  # truncate the *inner* text themselves before wrapping (see cmd_look) —
  # blind cut here may drop the closing tag and Telegram will 400 us.
  if [ ${#text} -gt 3900 ]; then text="${text:0:3850}

[…truncated]"; fi
  local args=(
    --data-urlencode "chat_id=$CHAT"
    --data-urlencode "parse_mode=HTML"
    --data-urlencode "text=$text"
  )
  [ -n "$markup" ] && args+=(--data-urlencode "reply_markup=$markup")
  # Drop curl -f so we get the body on HTTP 4xx (used to silently fail).
  # Append HTTP status via -w so we can log it on failure.
  local resp http body
  resp=$(curl -s -w $'\n__TGHTTP__%{http_code}' \
    "https://api.telegram.org/bot${TOKEN}/sendMessage" "${args[@]}" 2>&1)
  http="${resp##*__TGHTTP__}"
  body="${resp%$'\n'__TGHTTP__*}"
  if [ "$http" != "200" ] || ! echo "$body" | jq -e '.ok' >/dev/null 2>&1; then
    log "send_tg failed http=$http body=$(echo "$body" | head -c 300)"
  fi
}

# Build inline keyboard JSON for chat picker. Args:
#   $1 — action prefix (e.g. "chat", "close") sent as callback_data: "<action>:<role>/<slug>"
#   $2 — optional role filter
build_chat_keyboard() {
  local action="$1" role_filter="${2:-}"
  local rows="[]"
  while IFS= read -r role; do
    [ -n "$role_filter" ] && [ "$role" != "$role_filter" ] && continue
    while IFS='|' read -r pane sess win cmd slug; do
      [ -z "$pane" ] && continue
      local marker; case "$cmd" in 2.*|claude|claude-*) marker="✅" ;; *) marker="⚪" ;; esac
      local label="$marker $role/$slug"
      local data="${action}:${role}/${slug}"
      [ ${#data} -gt 60 ] && data="${data:0:60}"
      rows=$(echo "$rows" | jq --arg l "$label" --arg d "$data" '. += [[{text: $l, callback_data: $d}]]')
    done <<< "$(chats_for_role "$role")"
  done <<< "$(all_roles)"
  jq -nc --argjson kb "$rows" '{inline_keyboard: $kb}'
}

# Build inline keyboard for role picker (one button per role)
build_role_keyboard() {
  local action="$1"
  local rows="[]"
  while IFS= read -r role; do
    [ -z "$role" ] && continue
    local data="${action}:${role}"
    rows=$(echo "$rows" | jq --arg l "$role" --arg d "$data" '. += [[{text: $l, callback_data: $d}]]')
  done <<< "$(all_roles)"
  jq -nc --argjson kb "$rows" '{inline_keyboard: $kb}'
}

# Acknowledge a callback_query (dismisses the loading spinner client-side)
ack_callback() {
  curl -sf "https://api.telegram.org/bot${TOKEN}/answerCallbackQuery?callback_query_id=$1" -o /dev/null 2>/dev/null
}

active_chat_file() { echo "${ACTIVE_CHAT_FILE_PREFIX}.$1"; }

# Status message — single pinned Telegram message that always shows the
# current active chat + watcher count. Updated in-place via editMessageText
# whenever cmd_chat/cmd_new/cmd_end/cmd_close changes state.
STATUS_MSG_FILE=$STATE_DIR/status-msg-id

chat_alias() {
  local chat_id="$1" f
  f=$(alias_file)
  [ -f "$f" ] && grep -m1 "=${chat_id}$" "$f" | cut -d'=' -f1
}

build_status_text() {
  local tg_chat="$1"
  local active="(none)"
  local f; f=$(active_chat_file "$tg_chat")
  [ -s "$f" ] && active=$(cat "$f")
  local alias_label=""
  if [ "$active" != "(none)" ]; then
    local al; al=$(chat_alias "$active")
    [ -n "$al" ] && alias_label=" (<b>$al</b>)"
  fi
  local watchers=0
  for pf in "$STATE_DIR"/watch.*.pid; do
    [ -f "$pf" ] || continue
    local pid; pid=$(cat "$pf" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      watchers=$((watchers + 1))
    else
      rm -f "$pf"
    fi
  done
  echo "📍 active: <code>$active</code>${alias_label}
🔔 watchers: $watchers running"
}

update_status() {
  local tg_chat="${1:-$CHAT}"
  local content; content=$(build_status_text "$tg_chat")
  if [ -s "$STATUS_MSG_FILE" ]; then
    local mid; mid=$(cat "$STATUS_MSG_FILE")
    local resp
    resp=$(curl -sf "https://api.telegram.org/bot${TOKEN}/editMessageText" \
      --data-urlencode "chat_id=$tg_chat" \
      --data-urlencode "message_id=$mid" \
      --data-urlencode "parse_mode=HTML" \
      --data-urlencode "text=$content" 2>&1)
    # on success, unpin all then re-pin so clients always show the latest banner
    if echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
      curl -sf "https://api.telegram.org/bot${TOKEN}/unpinAllChatMessages" \
        --data-urlencode "chat_id=$tg_chat" -o /dev/null 2>/dev/null
      curl -sf "https://api.telegram.org/bot${TOKEN}/pinChatMessage" \
        --data-urlencode "chat_id=$tg_chat" \
        --data-urlencode "message_id=$mid" \
        --data-urlencode "disable_notification=true" -o /dev/null 2>/dev/null
      return
    fi
    # else fall through to recreate (message may have been deleted)
    log "editMessageText failed, recreating: $(echo "$resp" | head -c 200)"
  fi
  # First-time send + pin
  local resp mid
  resp=$(curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=$tg_chat" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$content" 2>&1)
  mid=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
  if [ -n "$mid" ]; then
    echo "$mid" > "$STATUS_MSG_FILE"
    # pin silently (best-effort; in DM bots can pin their own messages)
    curl -sf "https://api.telegram.org/bot${TOKEN}/pinChatMessage" \
      --data-urlencode "chat_id=$tg_chat" \
      --data-urlencode "message_id=$mid" \
      --data-urlencode "disable_notification=true" -o /dev/null 2>/dev/null
  fi
}

# Path to watcher scripts (sibling files, same dir).
SCRIPT_DIR_BOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SCRIPT_CLAUDE="$SCRIPT_DIR_BOT/chat-watcher.sh"
WATCHER_SCRIPT_CODEX="$SCRIPT_DIR_BOT/codex-watcher.sh"

# Phase 4 helpers — auto-push agent output to Telegram when chats respond.
watch_pid_file() { echo "$STATE_DIR/watch.$(echo "$1" | tr '/' '_').pid"; }
# Consecutive "pane is not an agent" observations before recover_watchers runs
# the destructive cleanup_dead_chat. A single dead reading can be a transient
# shell foreground or a pane mid-recreation (e.g. %1→%13 on maw wake), so we
# defer until DEAD_STRIKE_THRESHOLD sweeps agree the session really ended.
dead_strike_file() { echo "$STATE_DIR/deadstrike.$(echo "$1" | tr '/' '_')"; }
DEAD_STRIKE_THRESHOLD=${DEAD_STRIKE_THRESHOLD:-2}
user_send_marker() { echo "$STATE_DIR/last-user-send.$(echo "$1" | tr '/' '_')"; }
chat_runtime_file() { echo "$STATE_DIR/chat-runtime.$(echo "$1" | tr '/' '_').env"; }

normalize_engine() {
  case "${1:-}" in
    codex)  echo "codex" ;;
    *)      echo "claude" ;;
  esac
}

set_chat_engine() {
  local chat_id="$1" engine
  engine=$(normalize_engine "${2:-claude}")
  echo "ENGINE=$engine" > "$(chat_runtime_file "$chat_id")"
}

get_chat_engine() {
  local chat_id="$1" f
  f=$(chat_runtime_file "$chat_id")
  if [ -f "$f" ]; then
    local raw
    raw=$(grep -m1 '^ENGINE=' "$f" | cut -d'=' -f2-)
    [ -n "$raw" ] && { normalize_engine "$raw"; return; }
  fi
  echo "claude"
}

watcher_script_for_engine() {
  case "$1" in
    codex) echo "$WATCHER_SCRIPT_CODEX" ;;
    *)     echo "$WATCHER_SCRIPT_CLAUDE" ;;
  esac
}

stop_watcher_for() {
  local chat_id="$1"
  local f; f=$(watch_pid_file "$chat_id")
  if [ -f "$f" ]; then
    local pid; pid=$(cat "$f")
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$f"
  fi
}

start_watcher_for() {
  local pane="$1" chat_id="$2" engine="${3:-}"
  engine=$(normalize_engine "${engine:-$(get_chat_engine "$chat_id")}")
  set_chat_engine "$chat_id" "$engine"
  stop_watcher_for "$chat_id"  # idempotent — kill any prior watcher first
  local watcher_script
  watcher_script=$(watcher_script_for_engine "$engine")
  if [ ! -r "$watcher_script" ]; then
    log "watcher script not readable: $watcher_script (engine=$engine)"
    return 1
  fi
  nohup bash "$watcher_script" "$pane" "$chat_id" </dev/null >/dev/null 2>&1 &
  local watcher_pid=$!
  disown
  sleep 0.2
  if ! kill -0 "$watcher_pid" 2>/dev/null; then
    log "watcher exited immediately: $watcher_script (engine=$engine)"
    return 1
  fi
  return 0
}

# Returns 0 if the pane exists AND currently runs the claude/codex CLI (or its
# `node`/`bun` host). Returns 1 if the pane has reverted to a shell after the
# agent exited, or if the pane no longer exists at all. Used to gate watcher
# (re)spawn — once the agent process is gone, the watcher has no JSONL to tail
# and would just timeout + exit + respawn forever (observed 2026-05-29: chat
# `orchestrator/arra-oracle-v3.wt-c-macosmigrate` respawned 6× over ~60min on
# a pane that had reverted to zsh after the campaign ended).
is_session_alive_for() {
  local pane="$1" cmd
  [ -z "$pane" ] && return 1
  cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null) || return 1
  [ -z "$cmd" ] && return 1
  # Allow-list of known agent process names. Claude Code reports its CLI
  # `pane_current_command` as its OWN VERSION STRING (e.g. `2.1.150`,
  # `2.1.156`) rather than `claude` or `node` — observed live 2026-05-29
  # across panes %157/%158 (2.1.150), %216 (2.1.156), %0/%20/%4 (2.1.143).
  # Without the version-pattern arm, the first deploy of this guard treated
  # 9-of-13 live claude sessions as DEAD and dropped their watcher state.
  # Be explicit on "dead" (known shells) and permissive elsewhere so a future
  # Claude Code version bump won't re-trigger this regression.
  case "$cmd" in
    claude*|codex*|node*|bun*) return 0 ;;
    [0-9]*.[0-9]*.[0-9]*) return 0 ;;     # claude version-string form
    sh|bash|zsh|fish|tcsh|csh|ksh|dash) return 1 ;;  # known shells = session ended
    # Anything else (git, vim, less, a pager/REPL the agent shelled out to…) is
    # a TRANSIENT foreground command, NOT a dead session — the agent is alive in
    # the pane, just blocked on a child. Treating these as dead silently reaped
    # live watchers AND unbound the Telegram chat (cleanup_dead_chat), so an
    # orchestrator chat left running came back to a dropped, silent bridge. Be
    # permissive here, exactly as this function's header always intended; only a
    # reverted-to-shell pane (arm above) counts as ended.
    *) return 0 ;;                         # unknown foreground cmd — agent still alive
  esac
}

# Tear down the bot's tracking of a chat whose pane has reverted to a shell.
# Does NOT kill the pane — the user may want the zsh prompt there. Drops the
# watcher (idempotent), aliases, and runtime env. Worktree sweep is
# intentionally NOT called per-chat — sweep_orphan_worktrees is heavier and is
# already invoked at the end of cmd_close_all when the user explicitly closes.
# The active-chat marker is deliberately LEFT ALONE: it is the user's intent
# and only /chat, /end, /close should change it. Auto-clearing it here (plus
# the on-message resolve-miss paths, now also fixed) was silently unbinding the
# user, forcing a /chat on every return. If the chat is truly gone the next
# send just reports it unreachable and offers /relaunch — the binding stays.
cleanup_dead_chat() {
  local chat="$1"
  [ -z "$chat" ] && return
  stop_watcher_for "$chat"
  remove_aliases_for_chat "$chat" 2>/dev/null || true
  remove_runtime_for_chat "$chat" 2>/dev/null || true
}

# Boot recovery: scan all live chats and spawn watchers that aren't running.
# Called once on bot startup so chats survive a bot restart with auto-push intact.
# Periodically called from the main loop alongside reap_orphan_watchers.
recover_watchers() {
  local role
  while IFS= read -r role; do
    while IFS='|' read -r pane sess win cmd slug; do
      [ -z "$pane" ] && continue
      local chat="$role/$slug" engine
      # Session-alive guard: if the pane has reverted to a shell, the agent
      # exited (or the user `/exit`'d after a campaign). Stop respawning a
      # watcher that can never find a JSONL — clean up bot state instead.
      local sf; sf=$(dead_strike_file "$chat")
      if ! is_session_alive_for "$pane"; then
        # Multi-pane window guard: if another pane of THIS chat is still a live
        # agent, this dead pane is just a sibling (e.g. an exited team-subagent
        # in the orchestrator's window). Cleaning up would clobber the live
        # chat's watcher + aliases — the "session/alias keeps vanishing" bug.
        if chat_has_live_pane "$role" "$slug"; then
          rm -f "$sf" 2>/dev/null
          continue
        fi
        # One dead reading is not proof the session ended — require
        # DEAD_STRIKE_THRESHOLD consecutive sweeps before the destructive
        # cleanup (which drops the watcher AND the Telegram active-chat binding).
        local strikes; strikes=$(( $(cat "$sf" 2>/dev/null || echo 0) + 1 ))
        if [ "$strikes" -ge "$DEAD_STRIKE_THRESHOLD" ]; then
          rm -f "$sf" 2>/dev/null
          log "recover_watchers: $chat — pane $pane not an agent ×$strikes (cleaning up)"
          cleanup_dead_chat "$chat"
        else
          echo "$strikes" > "$sf"
          log "recover_watchers: $chat — pane $pane not an agent (strike $strikes/$DEAD_STRIKE_THRESHOLD, deferring)"
        fi
        continue
      fi
      rm -f "$sf" 2>/dev/null   # alive — clear any prior dead strikes
      local pf; pf=$(watch_pid_file "$chat")
      if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
        continue  # already running
      fi
      engine=$(get_chat_engine "$chat")
      [ "$engine" = "claude" ] && engine=$(detect_engine_from_cmd "$cmd")
      log "recover_watchers: spawning watcher for $chat ($pane)"
      start_watcher_for "$pane" "$chat" "$engine"
    done <<< "$(chats_for_role "$role")"
  done <<< "$(all_roles)"
}

# Kill chat-watcher processes whose tmux pane no longer exists. The bot's
# cmd_close path already reaps synchronously via stop_watcher_for; this is
# the safety net for orphans created by mass cleanup that bypasses cmd_close
# (e.g. `tmux kill-window` run by hand). Observed 2026-05-29 fleet cleanup
# (thread #257 P2): 39 watchers / 14 live windows → ~25 transient orphans
# that only self-exited after their next poll cycle noticed the dead pane.
# Called periodically alongside recover_watchers + once at the tail of
# cmd_close_all so the same sweep that closes also reaps.
reap_orphan_watchers() {
  local live_panes pid cmd pane chat reaped=0
  live_panes=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | tr '\n' ' ')
  # If we can't enumerate panes (no tmux), don't blindly kill — bail.
  [ -z "$live_panes" ] && return 0
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    cmd=$(ps -p "$pid" -o command= 2>/dev/null) || continue
    # chat-watcher.sh invocation: `bash <path>/chat-watcher.sh %<id> <role>/<slug>`
    pane=$(printf '%s' "$cmd" | awk '{print $3}')
    chat=$(printf '%s' "$cmd" | awk '{print $4}')
    # Guard against malformed lines — pane must look like a tmux pane id.
    case "$pane" in '%'[0-9]*) ;; *) continue ;; esac
    if [[ " $live_panes " != *" $pane "* ]]; then
      log "reap_orphan_watchers: chat=$chat pid=$pid pane=$pane → pane gone, killing"
      kill "$pid" 2>/dev/null
      [ -n "$chat" ] && rm -f "$(watch_pid_file "$chat")" 2>/dev/null
      reaped=$((reaped + 1))
    fi
  done < <(pgrep -f "chat-watcher.sh" 2>/dev/null)
  [ "$reaped" -gt 0 ] && log "reap_orphan_watchers: reaped $reaped orphan(s)"
  return 0
}

# Role registry lookups
role_session() {
  local role="$1" line
  for line in "${ROLES[@]}"; do
    case "$line" in "${role}|"*) echo "$line" | cut -d'|' -f2; return ;; esac
  done
}
role_repo() {
  local role="$1" line
  for line in "${ROLES[@]}"; do
    case "$line" in "${role}|"*) echo "$line" | cut -d'|' -f3; return ;; esac
  done
}
role_default_engine() {
  local role="$1" line raw
  for line in "${ROLES[@]}"; do
    case "$line" in "${role}|"*)
      raw=$(echo "$line" | cut -d'|' -f4)
      normalize_engine "$raw"
      return
      ;;
    esac
  done
  echo "claude"
}
all_roles() { for line in "${ROLES[@]}"; do echo "$line" | cut -d'|' -f1; done; }

# Enumerate chats for a role: every tmux pane whose window_name starts with
# "<role>-". Returns lines: <pane_id>|<session>|<window>|<cmd>|<slug>
chats_for_role() {
  local role="$1"
  tmux list-panes -a -F "#{pane_id}|#{session_name}|#{window_name}|#{pane_current_command}" 2>/dev/null \
    | awk -F'|' -v p="${role}-" 'index($3, p) == 1 { slug=substr($3, length(p)+1); print $0 "|" slug }'
}

# True if ANY pane mapped to <role>/<slug> is currently a live agent. A chat maps
# to a tmux WINDOW, and a window can hold several panes — e.g. an agent-teams
# window keeps the orchestrator pane PLUS its exited team-subagent panes (now
# zsh). Used so a dead sibling pane can't trigger cleanup of a chat whose primary
# pane is still alive (which would wrongly drop its watcher + aliases).
chat_has_live_pane() {
  local role="$1" slug="$2" _p _s _w _c _sl
  while IFS='|' read -r _p _s _w _c _sl; do
    [ "$_sl" = "$slug" ] || continue
    is_session_alive_for "$_p" && return 0
  done <<< "$(chats_for_role "$role")"
  return 1
}

# Resolve <role>/<slug> or just <role> to a pane line. Slug supports prefix
# match — e.g. "pg-writer/back" matches "pg-writer/backlog-20260428-..." if
# unique. Exact match wins over prefix match. Returns "" if ambiguous or
# not found.
alias_file() { echo "$STATE_DIR/aliases"; }

# Resolve alias name → role/slug (empty if not found)
resolve_alias() {
  local name="$1" f
  f=$(alias_file)
  [ -f "$f" ] && grep -m1 "^${name}=" "$f" | cut -d'=' -f2-
}

resolve_chat() {
  local target="$1"
  # Check alias first
  local via_alias
  via_alias=$(resolve_alias "$target")
  [ -n "$via_alias" ] && target="$via_alias"

  if [[ "$target" == *"/"* ]]; then
    local role="${target%%/*}" slug="${target#*/}"
    # exact match first
    local exact
    exact=$(chats_for_role "$role" | awk -F'|' -v s="$slug" '$5==s {print; exit}')
    [ -n "$exact" ] && { echo "$exact"; return; }
    # prefix match (substring at start of slug)
    local matches
    matches=$(chats_for_role "$role" | awk -F'|' -v s="$slug" 'index($5, s) == 1')
    local n
    n=$(echo "$matches" | grep -c .)
    [ "$n" = "1" ] && { echo "$matches"; return; }
    # 0 or >1: ambiguous; caller will list options
  else
    # bare <role>: only OK if exactly one chat exists
    local lines
    lines=$(chats_for_role "$target")
    [ "$(echo "$lines" | grep -c .)" = "1" ] && echo "$lines"
  fi
}

canonical_chat_from_target() {
  local target="$1" expanded resolved role slug via_alias
  via_alias=$(resolve_alias "$target")
  [ -n "$via_alias" ] && expanded="$via_alias" || expanded="$target"
  resolved=$(resolve_chat "$expanded")
  [ -z "$resolved" ] && return 1
  role="${expanded%%/*}"
  slug=$(echo "$resolved" | cut -d'|' -f5)
  echo "$role/$slug"
}

cmd_alias() {
  local tg_chat="$1" name="${2:-}" target="${3:-}"
  local f; f=$(alias_file)

  # /alias — list all
  if [ -z "$name" ]; then
    if [ ! -f "$f" ] || [ ! -s "$f" ]; then
      send_tg "📎 ยังไม่มี alias — ใช้ /alias &lt;name&gt; เพื่อตั้ง"
    else
      local out="📎 <b>Aliases:</b>
"
      while IFS='=' read -r n v; do
        out+="  <code>$n</code> → <code>$v</code>
"
      done < "$f"
      send_tg "$out"
    fi
    return
  fi

  # /alias rm <name> — remove. /alias rm alone falls here too — show usage instead
  # of setting "rm" as an alias for the active chat.
  if [ "$name" = "rm" ]; then
    if [ -z "$target" ]; then
      send_tg "❌ ใช้ <code>/alias rm &lt;name&gt;</code> เพื่อลบ — ดู /alias เพื่อดูรายชื่อ"
      return
    fi
    if [ -f "$f" ] && grep -q "^${target}=" "$f"; then
      sed -i '' "/^${target}=/d" "$f"
      send_tg "🗑 ลบ alias <code>$target</code> แล้ว"
    else
      send_tg "❌ ไม่เจอ alias <code>$target</code>"
    fi
    return
  fi

  # /alias <name> [role/slug] — set alias
  if [ -z "$target" ]; then
    local af; af=$(active_chat_file "$tg_chat")
    [ ! -f "$af" ] && { send_tg "❌ ไม่มี active chat — /chat ก่อน หรือระบุ /alias &lt;name&gt; &lt;role/slug&gt;"; return; }
    target=$(cat "$af")
  fi

  # validate target exists
  if [ -z "$(resolve_chat "$target")" ]; then
    send_tg "❌ ไม่เจอ chat <code>$target</code>"
    return
  fi

  # upsert: remove old entry for this name, append new
  touch "$f"
  sed -i '' "/^${name}=/d" "$f"
  echo "${name}=${target}" >> "$f"
  send_tg "✅ alias <code>$name</code> → <code>$target</code>
ใช้ /chat $name ได้เลย"
  update_status "$tg_chat"
}

# claude alive in pane = pane_current_command looks like a claude version (2.x)
is_claude() { case "$1" in 2.*|claude|claude-*) return 0 ;; *) return 1 ;; esac; }
is_codex() { case "$1" in codex|codex-*) return 0 ;; *) return 1 ;; esac; }
is_agent_cmd() { is_claude "$1" || is_codex "$1"; }

detect_engine_from_cmd() {
  if is_codex "$1"; then
    echo "codex"
  else
    echo "claude"
  fi
}

detect_engine_for_target() {
  local target="$1"
  local pane_cmd pane
  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  if [ -n "$pane" ]; then
    pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
    detect_engine_from_cmd "$pane_cmd"
    return
  fi
  echo "claude"
}

start_engine_in_pane() {
  local pane="$1" engine="$2" cmd pane_cmd attempts=0 max_attempts=20
  case "$engine" in
    codex)  cmd="codex --dangerously-bypass-approvals-and-sandbox" ;;
    *)      cmd="claude --dangerously-skip-permissions" ;;
  esac

  # Drain any live agent process first. Typing the new engine command while
  # the previous engine is still running injects a stray user turn instead of
  # restarting the pane process.
  while :; do
    pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
    [ -z "$pane_cmd" ] && return 1
    is_agent_cmd "$pane_cmd" || break
    attempts=$((attempts + 1))
    [ "$attempts" -le 4 ] && tmux send-keys -t "$pane" C-c 2>/dev/null
    sleep 0.5
    [ "$attempts" -ge "$max_attempts" ] && break
  done

  pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
  if is_agent_cmd "$pane_cmd"; then
    log "start_engine_in_pane: unable to stop prior agent cmd=$pane_cmd pane=$pane"
    return 1
  fi

  tmux send-keys -t "$pane" -- "$cmd" 2>/dev/null
  sleep 0.3
  tmux send-keys -t "$pane" Enter 2>/dev/null
  return 0
}

send_role_bootstrap_prompt() {
  local pane="$1" role="$2" engine="$3"
  local auto="${AUTO_BOOTSTRAP_ON_NEW:-1}"
  [ "$auto" = "0" ] && return 0
  local skill_path=".agent/skills/${role}/SKILL.md"
  local bootstrap="Bootstrap this session before any other work:
1) Read .agent/AGENTS.md
2) Read ${skill_path}
3) Confirm role identity as ${role}
4) Summarize active workflows and wait for my task."
  tmux send-keys -t "$pane" -- "$bootstrap" 2>/dev/null
  sleep 0.3
  tmux send-keys -t "$pane" Enter 2>/dev/null
  log "/new bootstrap sent for role=$role engine=$engine"
}

# Encode a path the way Claude Code does for ~/.claude/projects/ dir names:
# replace "/" with "-" and "." with "-". So /A/B.wt-1 → -A-B-wt-1.
encode_cwd() { echo "$1" | sed 's|/|-|g; s|\.|-|g'; }

# Find latest claude session JSONL for a worktree path
find_jsonl() {
  local cwd="$1"
  local enc=$(encode_cwd "$cwd")
  local dir=$HOME/.claude/projects/$enc
  [ ! -d "$dir" ] && return 1
  ls -t "$dir"/*.jsonl 2>/dev/null | head -1
}

find_codex_jsonl() {
  local cwd="$1" file file_cwd
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    file_cwd=$(head -n 1 "$file" 2>/dev/null | jq -r 'select(.type == "session_meta") | .payload.cwd // empty' 2>/dev/null)
    [ "$file_cwd" = "$cwd" ] && { echo "$file"; return; }
  done < <(find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null | sort -r | head -200)
}

codex_config_value() {
  local key="$1" cfg="$HOME/.codex/config.toml"
  [ -f "$cfg" ] || return
  grep -E "^${key}[[:space:]]*=" "$cfg" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[^=]+=[[:space:]]*//; s/^"//; s/"$//'
}

codex_pane_model_effort() {
  local pane="$1"
  [ -n "$pane" ] || return
  tmux capture-pane -p -t "$pane" -S -30 2>/dev/null \
    | sed -nE \
      -e 's/.*model:[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]\/]+).*/\1 \2/p' \
      -e 's/^[[:space:]]*([[:alnum:]._-]+)[[:space:]]+([[:alnum:]_-]+)[[:space:]]+·.*/\1 \2/p' \
    | tail -1
}

codex_model_cache_info() {
  local model="$1" cache="$HOME/.codex/models_cache.json"
  [ -n "$model" ] && [ -f "$cache" ] || return
  jq -r --arg model "$model" '
    (.models // [])[]
    | select(.slug == $model)
    | [
        ((.context_window // .max_context_window // 0) | tostring),
        ((.effective_context_window_percent // 0) | tostring)
      ]
    | join("\t")
  ' "$cache" 2>/dev/null | head -1
}

# ── Phase 1 read-only ──────────────────────────────────────────────────────

cmd_help() {
  send_tg '📖 <b>brew-ops bot</b>

<b>Read-only:</b>
/blockers /pending /threads — ops awareness

<b>Chat management:</b>
/roles                    list roles + chat counts
/chats [role]             list chats (all or by role)
/chat &lt;role[/slug]|alias&gt;  switch context (auto-pick if 1 chat)
/alias [name [role/slug]] set/list alias; /alias rm &lt;name&gt; ลบ
/new &lt;role&gt; [slug] [claude|codex]  spawn new chat (default=claude)
/relaunch [role/slug]     restart chat engine in existing pane
/close &lt;role/slug&gt;        kill chat (pane + leaves worktree orphan)
/close all [auto]         audit + close safe chats; sweep orphan wt/aliases

<b>Active chat I/O:</b>
&lt;plain msg&gt;               → send to current chat
/key [role/slug] &lt;keys…&gt;   ⌨️ TUI nav: up down enter esc … (stuck-menu)
/look [N|full]            tmux scrollback (default 25)
/end                      clear active chat (no kill)
/watch list|on|off|all    🔔 manage per-chat auto-push

<b>History:</b>
/history [target] [N]     claude JSONL (last N turns; default 20)
/retro [role] [N]         workflow retros (default 5)
/closed                   recently-ended chats with JSONL still on disk
/ctx [role/slug]          context window usage % for active (or named) chat
/quota                    Claude Code usage window / reset estimate

<b>Power:</b>
/list                     raw tmux panes (incl watcher-spawned)

Push: detector ทุก 5 min → alert ถ้ามี <code>[BLOCK_*]</code> ใน main'
}

cmd_blockers() {
  local out="🔴 <b>Active blockers ใน main:</b>

" found=0
  for repo in "${REPOS[@]}"; do
    [ ! -d "$repo/docs" ] && continue
    local hits
    hits=$(grep -rEoh '\[(BLOCK_[A-Z_]+|SECURITY_HOLD):[0-9]+\]' "$repo/docs" 2>/dev/null | sort -u)
    if [ -n "$hits" ]; then
      out+="<b>$(basename "$repo"):</b>
<pre>$(echo "$hits" | html_escape)</pre>

"
      found=1
    fi
  done
  [ "$found" -eq 0 ] && out+="✅ ไม่มี active blockers ตอนนี้"
  send_tg "$out"
}

cmd_pending() {
  local out="🟡 <b>Pending markers</b> (handoff, ไม่ block merge):

"
  for repo in "${REPOS[@]}"; do
    [ ! -d "$repo/docs" ] && continue
    local awaiting ratify
    awaiting=$(grep -rEoh '\[AWAITING_[A-Z_]+:[0-9]+\]' "$repo/docs" 2>/dev/null | sort | uniq -c | sort -rn | head -8)
    ratify=$(grep -rEoh '\[RATIFICATION_PENDING:[0-9]+\]' "$repo/docs" 2>/dev/null | sort | uniq -c | sort -rn | head -8)
    if [ -n "$awaiting" ] || [ -n "$ratify" ]; then
      out+="<b>$(basename "$repo"):</b>
"
      [ -n "$awaiting" ] && out+="<pre>$(echo "$awaiting" | html_escape)</pre>
"
      [ -n "$ratify" ] && out+="<pre>$(echo "$ratify" | html_escape)</pre>
"
      out+="
"
    fi
  done
  if [ -f "$ORACLE_DB" ]; then
    local n; n=$("$SQLITE" "$ORACLE_DB" "SELECT COUNT(*) FROM forum_threads WHERE status='pending'" 2>/dev/null)
    out+="<b>Open arra_threads:</b> ${n:-?} (/threads)"
  fi
  send_tg "$out"
}

cmd_threads() {
  local mode="${1:-all}"
  [ ! -f "$ORACLE_DB" ] && { send_tg "❌ Oracle DB ไม่เจอที่ $ORACLE_DB"; return; }
  local q
  if [ "$mode" = "recent" ]; then
    q="SELECT id || ' [' || status || '] [' || coalesce(project,'-') || '] ' || substr(title, 1, 60) FROM (SELECT * FROM forum_threads ORDER BY id DESC LIMIT 20) WHERE status != 'closed' ORDER BY id DESC"
  else
    q="SELECT id || ' [' || coalesce(project,'-') || '] ' || substr(title, 1, 60) FROM forum_threads WHERE status='pending' ORDER BY id DESC"
  fi
  local rows total
  rows=$("$SQLITE" "$ORACLE_DB" "$q" 2>/dev/null)
  if [ -z "$rows" ]; then send_tg "✅ ไม่มี open threads"; return; fi
  total=$("$SQLITE" "$ORACLE_DB" "SELECT COUNT(*) FROM forum_threads WHERE status='pending'" 2>/dev/null)
  send_tg "💬 <b>Open arra_threads:</b> $total
<pre>$(echo "$rows" | html_escape)</pre>"
}

# ── Phase 2 raw tmux ───────────────────────────────────────────────────────

cmd_list() {
  local panes
  panes=$(tmux list-panes -a -F "#{pane_id} #{session_name}:#{window_name} cmd=#{pane_current_command}" 2>/dev/null)
  [ -z "$panes" ] && { send_tg "ℹ️ tmux server ไม่ทำงาน (ไม่มี session/pane)
ใช้ /new &lt;role&gt; [slug] เพื่อสร้าง chat แรก — maw จะ boot tmux ให้เอง"; return; }
  send_tg "🪟 <b>tmux panes (raw):</b>
<pre>$(echo "$panes" | html_escape)</pre>"
}

# ── Phase 3a chat management ───────────────────────────────────────────────

cmd_roles() {
  local out="🎭 <b>Roles:</b>

"
  while IFS= read -r role; do
    local n cmds
    cmds=$(chats_for_role "$role")
    n=$(echo "$cmds" | grep -c .)
    [ "$n" = "0" ] && out+="⚪ <b>$role</b> — no chat
" && continue
    local active=0
    while IFS='|' read -r _ _ _ cmd _; do
      is_agent_cmd "$cmd" && active=$((active + 1))
    done <<< "$cmds"
    out+="✅ <b>$role</b> — $n chat(s), $active active
"
  done <<< "$(all_roles)"
  out+="
ใช้ /chats &lt;role&gt; ดูรายละเอียด หรือ /new &lt;role&gt; [slug] สร้าง chat ใหม่"
  send_tg "$out"
}

cmd_chats() {
  local filter="${1:-}"
  local out="💬 <b>Chats</b>"
  [ -n "$filter" ] && out+=" (role=$filter)"
  out+=":

"
  local found=0
  while IFS= read -r role; do
    [ -n "$filter" ] && [ "$role" != "$filter" ] && continue
    while IFS='|' read -r pane sess win cmd slug; do
      [ -z "$pane" ] && continue
      local marker engine
      is_agent_cmd "$cmd" && marker="✅" || marker="⚪"
      engine=$(get_chat_engine "$role/$slug")
      [ "$engine" = "claude" ] && engine=$(detect_engine_from_cmd "$cmd")
      out+="$marker <code>$role/$slug</code> $pane (cmd=$cmd, engine=$engine)
"
      found=1
    done <<< "$(chats_for_role "$role")"
  done <<< "$(all_roles)"
  [ "$found" = "0" ] && out+="(ยังไม่มี chats)"
  out+="

✅=agent alive (claude/codex)  ⚪=zsh idle"
  send_tg "$out"
}

cmd_chat() {
  local tg_chat="$1" target="$2"
  if [ -z "$target" ]; then
    # No arg → show inline keyboard with all chats
    local kb; kb=$(build_chat_keyboard "chat")
    local has_chats
    has_chats=$(echo "$kb" | jq -r '.inline_keyboard | length')
    if [ "${has_chats:-0}" = "0" ]; then
      send_tg "ยังไม่มี chats — /new &lt;role&gt; [slug] เพื่อสร้าง"
      return
    fi
    send_tg "💬 เลือก chat:" "$kb"
    return
  fi
  local resolved
  resolved=$(resolve_chat "$target")
  if [ -z "$resolved" ]; then
    # bare role with 0 or >1 chats
    local lines n
    lines=$(chats_for_role "$target")
    n=$(echo "$lines" | grep -c .)
    if [ "$n" = "0" ]; then
      send_tg "❌ <b>$target</b> ยังไม่มี chat — ใช้ /new $target"
    elif [ "$n" -gt 1 ]; then
      send_tg "❓ <b>$target</b> มี $n chats — ระบุ slug:
<pre>$(echo "$lines" | awk -F'|' '{printf "/chat %s/%s  (%s)\n", "'"$target"'", $5, $1}' | html_escape)</pre>"
    else
      send_tg "❌ /chat $target ผิด — ระบุ /chat $target/&lt;slug&gt;"
    fi
    return
  fi
  local pane sess win cmd slug
  IFS='|' read -r pane sess win cmd slug <<< "$resolved"
  local role="${win%%-*}"
  # Reconstruct role from window prefix more carefully: role can contain dashes (e.g. "bot-writer")
  while IFS= read -r r; do
    case "$win" in "${r}-"*) role="$r"; slug="${win#${r}-}"; break ;; esac
  done <<< "$(all_roles)"
  local chat_key="$role/$slug" engine
  engine=$(get_chat_engine "$chat_key")
  if [ "$engine" = "claude" ]; then
    engine=$(detect_engine_from_cmd "$cmd")
  fi
  set_chat_engine "$chat_key" "$engine"
  echo "$chat_key" > "$(active_chat_file "$tg_chat")"
  # Phase 4 v2: each chat has its own watcher (independent of active context).
  # /chat just routes plain messages — doesn't toggle the watcher.
  # If pane's watcher isn't running (e.g. after bot restart), spawn it.
  if [ ! -f "$(watch_pid_file "$chat_key")" ] || ! kill -0 "$(cat "$(watch_pid_file "$chat_key")" 2>/dev/null)" 2>/dev/null; then
    watch_note=""
    if ! start_watcher_for "$pane" "$chat_key" "$engine"; then
      watch_note="
⚠️ watcher start failed — ใช้ /watch on <code>$chat_key</code> หลังตรวจ log"
    fi
  fi
  local al; al=$(chat_alias "$chat_key")
  local al_label; [ -n "$al" ] && al_label=" (<b>$al</b>)" || al_label=""
  send_tg "✓ active chat: <code>$chat_key</code>${al_label} ($pane, cmd=$cmd, engine=$engine)
ส่งข้อความตอนนี้ → ไป chat นี้
/watch ดู watcher status, /look /history ดูเนื้อหา${watch_note:-}"
  update_status "$tg_chat"
}

cmd_new() {
  local tg_chat="$1" role="$2" arg3="${3:-}" arg4="${4:-}"
  local slug engine
  if [ "$arg3" = "claude" ] || [ "$arg3" = "codex" ]; then
    slug="$(date +%Y%m%d-%H%M%S)"
    engine="$arg3"
  else
    slug="${arg3:-$(date +%Y%m%d-%H%M%S)}"
    engine=$(normalize_engine "${arg4:-$(role_default_engine "$role")}")
  fi
  [ -z "$role" ] && { send_tg "❌ usage: /new &lt;role&gt; [slug] [claude|codex]"; return; }
  local repo
  repo=$(role_repo "$role")
  [ -z "$repo" ] && { send_tg "❌ unknown role: $role (ใช้ /roles)"; return; }
  audit "/new $role $slug engine=$engine"

  # Dead-cwd guard. `maw` runs on bun; bun aborts with "The current working
  # directory was deleted…" if its process inherits a cwd that no longer
  # exists on disk. That happens when the bot was started from (or a prior
  # worktree-removal deleted) the directory the bot process sits in — every
  # `$(maw …)` / `$(git …)` command-substitution inherits that dead cwd and
  # fails, surfacing as "pane … ไม่ถูกสร้าง". Re-anchor to a directory that is
  # guaranteed to exist before any git/maw call. `git -C` uses absolute paths
  # so this only needs to make getcwd() succeed, not point anywhere specific.
  if ! pwd -P >/dev/null 2>&1; then
    cd "$repo" 2>/dev/null || cd "$HOME" 2>/dev/null || cd / 2>/dev/null
    log "/new $role/$slug — bot cwd was deleted; re-anchored to $(pwd -P 2>/dev/null)"
  fi

  # Pre-flight: ensure local main is current with origin/main so the worktree
  # forks from latest base. Two paths depending on what's checked out in the
  # main worktree of the repo:
  #   (a) main is HEAD       → `git pull --ff-only` (touches working tree)
  #   (b) main is NOT HEAD   → `git fetch + update-ref` (working tree untouched)
  # Either way, fail loudly on conflict / non-FF / dirty tree — don't silently
  # spawn from stale base.
  send_tg "⏳ <b>$role/$slug</b>: refreshing main in $(basename "$repo")..."
  local cur_branch
  cur_branch=$(git -C "$repo" branch --show-current 2>/dev/null)

  # Always fetch first (cheap, common to both paths)
  local fetch_out fetch_rc
  fetch_out=$(git -C "$repo" fetch origin main 2>&1)
  fetch_rc=$?
  if [ $fetch_rc -ne 0 ]; then
    send_tg "❌ <b>fetch failed</b> in $(basename "$repo")
<pre>$(echo "$fetch_out" | html_escape)</pre>"
    return
  fi

  # Sync local main to origin/main
  if [ "$cur_branch" = "main" ]; then
    # path (a): merge ff-only into checked-out main; fails on dirty tree / non-FF
    local merge_out merge_rc
    merge_out=$(git -C "$repo" merge --ff-only origin/main 2>&1)
    merge_rc=$?
    if [ $merge_rc -ne 0 ]; then
      local status
      status=$(git -C "$repo" status --short 2>&1 | head -8)
      send_tg "❌ <b>ff merge failed</b> in $(basename "$repo") (on branch <code>main</code>)
<pre>$(echo "$merge_out" | html_escape)</pre>
status:
<pre>$(echo "${status:-(clean)}" | html_escape)</pre>
แก้ conflict / commit-or-stash dirty files แล้ว /new ใหม่"
      return
    fi
  else
    # path (b): main is not HEAD — update ref directly (doesn't touch working tree)
    # Verify FF first so we don't silently rewind history
    if ! git -C "$repo" merge-base --is-ancestor main origin/main 2>/dev/null; then
      send_tg "❌ local main ของ $(basename "$repo") <b>ไม่ใช่ ancestor ของ origin/main</b> (diverged)
ปัจจุบัน checked out: <code>$cur_branch</code>
ต้อง resolve manually (rebase main onto origin/main หรือ reset)"
      return
    fi
    git -C "$repo" update-ref refs/heads/main origin/main 2>/dev/null
  fi

  local pulled_head
  pulled_head=$(git -C "$repo" rev-parse --short main 2>/dev/null)

  send_tg "✓ pulled main → <code>$pulled_head</code>
⏳ spawning <code>$role/$slug</code>..."

  # maw wake creates worktree + pane. We'll align the pane engine afterward
  # (claude or codex), independent from maw's default template command.
  local out
  out=$(maw wake "$role" --wt "$slug" --fresh 2>&1 | tail -8)
  log "/new $role/$slug (engine=$engine) — maw wake output: $out"
  sleep 2
  # find the pane maw created
  local pane
  pane=$(tmux list-panes -a -F "#{pane_id}|#{window_name}" 2>/dev/null | awk -F'|' -v w="${role}-${slug}" '$2==w{print $1; exit}')
  if [ -z "$pane" ]; then
    send_tg "❌ pane <code>${role}-${slug}</code> ไม่ถูกสร้าง — ดู maw output:
<pre>$(echo "$out" | html_escape)</pre>"
    return
  fi
  # Wait for maw's template to settle, then enforce desired engine in pane.
  sleep 3
  local pane_cmd target_engine restarted=0
  target_engine=$(normalize_engine "$engine")
  local chat_key="$role/$slug"
  set_chat_engine "$chat_key" "$target_engine"
  pane_cmd=$(tmux list-panes -t "$pane" -F "#{pane_current_command}" 2>/dev/null | head -1)
  if echo "$pane_cmd" | grep -qE '^(zsh|bash|sh|fish)$'; then
    log "/new $role/$slug — pane at $pane_cmd, starting $target_engine"
    if ! start_engine_in_pane "$pane" "$target_engine"; then
      send_tg "❌ start $target_engine failed for <code>$chat_key</code> (pane=$pane, cmd=$pane_cmd)"
      return
    fi
    restarted=1
    sleep 3
  elif { [ "$target_engine" = "claude" ] && is_codex "$pane_cmd"; } || \
       { [ "$target_engine" = "codex" ] && is_claude "$pane_cmd"; }; then
    log "/new $role/$slug — pane has $pane_cmd, switching to $target_engine"
    if ! start_engine_in_pane "$pane" "$target_engine"; then
      send_tg "❌ switch to $target_engine failed for <code>$chat_key</code> (pane=$pane, cmd=$pane_cmd)"
      return
    fi
    restarted=1
    sleep 3
  else
    log "/new $role/$slug — pane already running $pane_cmd (engine=$target_engine), skip restart"
  fi
  echo "$chat_key" > "$(active_chat_file "$tg_chat")"
  local watch_msg
  if start_watcher_for "$pane" "$chat_key" "$target_engine"; then
    watch_msg="🔔 auto-push เปิดอยู่"
  else
    watch_msg="⚠️ auto-push start ไม่สำเร็จ — ใช้ /watch on <code>$chat_key</code> หลังตรวจ log"
  fi
  [ "$restarted" = "1" ] && send_role_bootstrap_prompt "$pane" "$role" "$target_engine"
  send_tg "✓ created <code>$chat_key</code> ($pane, engine=$target_engine)
✓ now active chat
$watch_msg
ส่งข้อความเริ่มคุย หรือ /look ดู splash"
  update_status "$tg_chat"
}

# Audit a single chat for /close all. Echoes "OK" if safe to close, else
# "KEEP: <reason>". Skips oracle baselines outright.
audit_chat_for_close() {
  local pane="$1" slug="$2"
  case "$slug" in oracle|main) echo "KEEP: oracle baseline"; return ;; esac
  local cwd
  cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
  [ -z "$cwd" ] || [ ! -d "$cwd" ] && { echo "OK"; return; }
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || { echo "OK"; return; }
  local dirty; dirty=$(git -C "$cwd" status --porcelain 2>/dev/null | head -1)
  [ -n "$dirty" ] && { echo "KEEP: dirty ($cwd)"; return; }
  local head; head=$(git -C "$cwd" rev-parse HEAD 2>/dev/null)
  if [ -n "$head" ]; then
    local on_remote; on_remote=$(git -C "$cwd" branch -r --contains "$head" 2>/dev/null | head -1)
    [ -z "$on_remote" ] && { echo "KEEP: unpushed (HEAD ${head:0:7} not on any remote)"; return; }
  fi
  echo "OK"
}

# Remove all alias entries pointing to a given role/slug
remove_aliases_for_chat() {
  local chat="$1" f; f=$(alias_file)
  [ -f "$f" ] || return
  local tmp; tmp=$(mktemp)
  awk -F= -v c="$chat" 'NF>=2 { v=substr($0, index($0,"=")+1); if (v != c) print }' "$f" > "$tmp" && mv "$tmp" "$f"
}

remove_runtime_for_chat() {
  local chat="$1" f
  f=$(chat_runtime_file "$chat")
  [ -f "$f" ] && rm -f "$f"
}

# Safe worktree remove (no -f). No-op for the main repo dir or missing path.
remove_worktree_for_chat() {
  local cwd="$1" repo="$2"
  [ -z "$cwd" ] || [ -z "$repo" ] || [ "$cwd" = "$repo" ] && return 0
  [ -d "$cwd" ] || return 0
  git -C "$repo" worktree remove "$cwd" 2>/dev/null
}

# Sweep orphan worktrees: clean + pushed + no live tmux pane
sweep_orphan_worktrees() {
  local r wt_path h on_remote in_use pane_path
  local panes; panes=$(tmux list-panes -a -F "#{pane_current_path}" 2>/dev/null)
  for r in "${REPOS[@]}"; do
    [ -e "$r/.git" ] || continue
    while IFS= read -r wt_path; do
      [ -z "$wt_path" ] || [ "$wt_path" = "$r" ] && continue
      [ -d "$wt_path" ] || continue
      in_use="no"
      while IFS= read -r pane_path; do
        [ "$pane_path" = "$wt_path" ] && in_use="yes" && break
      done <<< "$panes"
      [ "$in_use" = "yes" ] && continue
      [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null | head -1)" ] && continue
      h=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)
      if [ -n "$h" ]; then
        on_remote=$(git -C "$wt_path" branch -r --contains "$h" 2>/dev/null | head -1)
        [ -z "$on_remote" ] && continue
      fi
      git -C "$r" worktree remove "$wt_path" 2>/dev/null && audit "/close all → swept orphan $wt_path"
    done < <(git -C "$r" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
    git -C "$r" worktree prune 2>/dev/null
  done
}

# Sweep alias entries pointing to non-existent chats
sweep_orphan_aliases() {
  local f; f=$(alias_file)
  [ -f "$f" ] && [ -s "$f" ] || return
  local tmp; tmp=$(mktemp)
  local aname aval
  while IFS='=' read -r aname aval; do
    [ -z "$aname" ] && continue
    if [ -n "$(resolve_chat "$aval")" ]; then
      echo "${aname}=${aval}" >> "$tmp"
    else
      audit "/close all → swept orphan alias $aname → $aval"
    fi
  done < "$f"
  mv "$tmp" "$f"
}

# /close all [auto] — audit every chat, close safe ones, then sweep orphan
# worktrees + aliases. "auto" mode is currently identical to plain "all";
# reserved for future "wrap-up-and-close finishable" behaviour.
cmd_close_all() {
  local mode="${1:-}"
  local closed=0 kept=""
  local role pane sess win cmd slug chat verdict cwd repo
  while IFS= read -r role; do
    [ -z "$role" ] && continue
    while IFS='|' read -r pane sess win cmd slug; do
      [ -z "$pane" ] && continue
      chat="$role/$slug"
      verdict=$(audit_chat_for_close "$pane" "$slug")
      if [ "$verdict" = "OK" ]; then
        cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
        repo=$(role_repo "$role")
        stop_watcher_for "$chat"
        tmux kill-pane -t "$pane" 2>/dev/null
        remove_aliases_for_chat "$chat"
        remove_runtime_for_chat "$chat"
        remove_worktree_for_chat "$cwd" "$repo"
        local af; af=$(active_chat_file "$CHAT")
        [ -s "$af" ] && [ "$(cat "$af" 2>/dev/null)" = "$chat" ] && rm -f "$af"
        audit "/close all → closed $chat ($pane)"
        closed=$((closed + 1))
      else
        kept+="
  • <code>$chat</code> — ${verdict#KEEP: }"
        audit "/close all → kept $chat: $verdict"
      fi
    done <<< "$(chats_for_role "$role")"
  done <<< "$(all_roles)"

  sweep_orphan_worktrees
  sweep_orphan_aliases
  reap_orphan_watchers   # final pass: any pane killed out-of-band mid-loop

  local summary="✅ <b>/close all${mode:+ $mode}</b> — closed: <b>$closed</b>"
  [ -n "$kept" ] && summary+="
🛡 kept alive:$kept"
  send_tg "$summary"
  update_status "$CHAT"
}

cmd_close() {
  local target="$1" mode="${2:-}"
  if [ "$target" = "all" ]; then
    cmd_close_all "$mode"
    return
  fi
  if [ -z "$target" ]; then
    local kb; kb=$(build_chat_keyboard "close")
    local has_chats
    has_chats=$(echo "$kb" | jq -r '.inline_keyboard | length')
    if [ "${has_chats:-0}" = "0" ]; then
      send_tg "ยังไม่มี chats ให้ปิด"
      return
    fi
    send_tg "✖️ เลือก chat ที่จะปิด:" "$kb"
    return
  fi
  # Track if active chat is being closed → clear it
  local active_f; active_f=$(active_chat_file "$CHAT")
  local active_now=""
  [ -s "$active_f" ] && active_now=$(cat "$active_f")
  local resolved
  resolved=$(resolve_chat "$target")
  [ -z "$resolved" ] && { send_tg "❌ ไม่เจอ chat <code>$target</code>"; return; }
  local pane
  pane=$(echo "$resolved" | cut -d'|' -f1)
  audit "/close $target ($pane)"
  tmux kill-pane -t "$pane" 2>/dev/null
  # Drop any aliases pointing at the closed chat so they don't dangle.
  # Derive canonical role/slug: expand alias (if $target was one) for the
  # role half, take field 5 of the resolved pane line for the slug.
  local _expanded="$target" _via
  _via=$(resolve_alias "$target"); [ -n "$_via" ] && _expanded="$_via"
  local _canon_chat="${_expanded%%/*}/$(echo "$resolved" | cut -d'|' -f5)"
  stop_watcher_for "$_canon_chat"
  remove_aliases_for_chat "$_canon_chat"
  remove_runtime_for_chat "$_canon_chat"
  # If we just killed the active chat, clear active state
  # (resolve_chat may have prefix-matched, so compare resolved target)
  local resolved_target="$target"
  # Try to derive the canonical role/slug we just closed from the resolved line
  local closed_role closed_slug
  while IFS= read -r r; do
    case "$pane" in *) ;; esac
    # not strictly needed; keep target as-is and just clear if matches active
  done <<< ""
  if [ -n "$active_now" ] && [[ "$active_now" == "$target" || "$active_now" == "${target%%/*}/"* ]]; then
    # imprecise but ok: clear active if any close-match
    rm -f "$active_f"
  fi
  send_tg "✓ closed <code>$target</code> ($pane)
หมายเหตุ: worktree ของ chat นี้ยัง orphan — รัน <code>git worktree prune</code> ใน repo นั้น"
  update_status "$CHAT"
}

# ── Phase 3b history ───────────────────────────────────────────────────────

cmd_look() {
  local tg_chat="$1" arg="${2:-25}"
  local f; f=$(active_chat_file "$tg_chat")
  [ ! -f "$f" ] && { send_tg "❌ ไม่มี active chat — /chat ก่อน"; return; }
  local target pane
  target=$(cat "$f")
  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  # Pane not resolvable right now — could be transient (agent shelled out to a
  # foreground cmd, tmux mid-rebuild) OR genuinely gone. Do NOT delete the
  # active-chat marker: it is the user's intent and a single flaky lookup was
  # silently unbinding them, forcing /chat on every return. Keep it sticky;
  # only /chat, /end, /close change it. Tell them it's unreachable + how to act.
  [ -z "$pane" ] && { send_tg "⚠️ active chat <code>$target</code> ส่งไม่ได้ตอนนี้ (pane ไม่เจอ — agent อาจกำลังรันคำสั่ง หรือเพิ่งปิด). binding ยังอยู่ — ลองใหม่อีกครั้ง, หรือ <code>/relaunch $target</code>, หรือ <code>/end</code> เพื่อล้าง"; return; }
  local n
  case "$arg" in
    full|all) n=5000 ;;
    *)        n="$arg" ;;
  esac
  # Capture raw, then choose a delivery path:
  #   long  → publish full capture as a secret Gist (.txt for monospaced
  #           render — TUI box-drawing chars look right and GitHub doesn't
  #           try to parse markdown), Telegram preview links to it.
  #   short → inline <pre>, escaped + line-bounded truncation under a
  #           3700-char budget so the header + <pre></pre> wrapper stays
  #           under Telegram's 4096-char message cap. Truncating *after*
  #           wrapping (the pre-fix behaviour) could chop the closing
  #           </pre> or split a UTF-8 sequence and silently 400.
  local raw raw_len
  raw=$(tmux capture-pane -t "$pane" -pS "-$n" 2>/dev/null)
  raw_len=${#raw}
  if [ "$raw_len" -gt "$GIST_THRESHOLD" ]; then
    local title="/look ${target} (${pane}, ${n} lines) — $(date '+%Y-%m-%d %H:%M')"
    local url; url=$(gist_publish "$title" "$raw" "txt")
    if [ -n "$url" ]; then
      local preview
      preview=$(printf '%s' "$raw" \
        | html_escape \
        | awk -v BUDGET=600 'BEGIN{tot=0}
            { if (tot + length($0) + 1 > BUDGET) exit
              tot += length($0) + 1; print }')
      send_tg "👁️ <code>$target</code> (${pane}, ${n} lines, ${raw_len} chars):
<pre>$preview</pre>
…
📖 <a href=\"$url\">read full on gist</a>"
      return
    fi
    # gist failed → fall through to truncated inline (still useful, just
    # shorter than full). Logged via send_tg's diagnostics if it 400s.
  fi
  local content
  content=$(printf '%s' "$raw" \
    | html_escape \
    | awk -v BUDGET=3700 'BEGIN{tot=0}
        { if (tot + length($0) + 1 > BUDGET) { print "[…truncated]"; exit }
          tot += length($0) + 1; print }')
  send_tg "👁️ <code>$target</code> ($pane, $n lines):
<pre>$content</pre>"
}

cmd_end() {
  local tg_chat="$1"
  rm -f "$(active_chat_file "$tg_chat")"
  send_tg "✓ cleared active chat (watchers ยังเปิดอยู่ — ใช้ /watch off &lt;chat&gt; ถ้าจะเงียบ)"
  update_status "$tg_chat"
}

# /relaunch — re-spawn the chat engine in an existing pane.
# Different from /new: keeps the pane + worktree, just restarts inside.
cmd_relaunch() {
  local tg_chat="$1" target="${2:-}"
  if [ -z "$target" ]; then
    local f; f=$(active_chat_file "$tg_chat")
    [ ! -f "$f" ] && { send_tg "❌ ไม่มี active chat — /chat ก่อน หรือ /relaunch &lt;role/slug&gt;"; return; }
    target=$(cat "$f")
  fi
  # Resolve alias if user passed one
  local via_alias; via_alias=$(resolve_alias "$target")
  [ -n "$via_alias" ] && target="$via_alias"
  local pane; pane=$(resolve_chat "$target" | cut -d'|' -f1)
  [ -z "$pane" ] && { send_tg "❌ chat <code>$target</code> ไม่เจอ pane (ตายแล้ว?) — ใช้ /new ถ้าจะสร้างใหม่"; return; }
  local pane_cmd
  pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
  local engine
  engine=$(get_chat_engine "$target")
  [ "$engine" = "claude" ] && engine=$(detect_engine_from_cmd "$pane_cmd")
  set_chat_engine "$target" "$engine"
  if [ "$engine" = "claude" ] && is_claude "$pane_cmd"; then
    send_tg "✓ claude รันอยู่แล้วใน <code>$target</code> (cmd=<code>$pane_cmd</code>) — ไม่ต้อง relaunch"
    return
  fi
  if [ "$engine" = "codex" ] && is_codex "$pane_cmd"; then
    send_tg "✓ codex รันอยู่แล้วใน <code>$target</code> (cmd=<code>$pane_cmd</code>) — ไม่ต้อง relaunch"
    return
  fi
  audit "/relaunch $target pane=$pane prev_cmd=$pane_cmd engine=$engine"
  if ! start_engine_in_pane "$pane" "$engine"; then
    send_tg "❌ relaunch $engine failed in <code>$target</code> (pane=$pane, cmd=<code>${pane_cmd:-?}</code>)"
    return
  fi
  local watch_msg
  if start_watcher_for "$pane" "$target" "$engine"; then
    watch_msg="watcher started"
  else
    watch_msg="watcher start failed"
  fi
  send_tg "🔄 relaunch $engine ใน <code>$target</code> (was <code>${pane_cmd:-?}</code>, $watch_msg) — รอสักครู่ให้ขึ้น แล้วลองส่งข้อความใหม่"
}

cmd_watch() {
  local sub="${1:-list}" target="${2:-}"
  case "$sub" in
    list)
      local out="🔔 <b>Watchers running:</b>

"
      local found=0
      for f in "$STATE_DIR"/watch.*.pid; do
        [ ! -f "$f" ] && continue
        local pid; pid=$(cat "$f" 2>/dev/null)
        local chat; chat=$(basename "$f" | sed 's/^watch\.//; s/\.pid$//; s/_/\//')
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          out+="✅ <code>$chat</code> (pid=$pid)
"
          found=1
        else
          rm -f "$f"  # stale
        fi
      done
      [ "$found" = "0" ] && out+="(none)"
      send_tg "$out"
      ;;
    on)
      [ -z "$target" ] && {
        # default = active chat
        local f; f=$(active_chat_file "$CHAT")
        [ -f "$f" ] && target=$(cat "$f")
      }
      [ -z "$target" ] && { send_tg "❌ usage: /watch on &lt;role/slug&gt;"; return; }
      local resolved canon
      resolved=$(resolve_chat "$target")
      [ -z "$resolved" ] && { send_tg "❌ ไม่เจอ chat <code>$target</code>"; return; }
      canon=$(canonical_chat_from_target "$target")
      local pane engine; pane=$(echo "$resolved" | cut -d'|' -f1)
      engine=$(get_chat_engine "$canon")
      if ! start_watcher_for "$pane" "$canon" "$engine"; then
        send_tg "❌ watcher start failed for <code>$canon</code> ($pane, engine=$engine) — ดู <code>~/.cache/brew-ops-bot/*watcher.log</code>"
        return
      fi
      send_tg "✓ watcher on for <code>$canon</code> ($pane, engine=$engine)"
      ;;
    off)
      [ -z "$target" ] && {
        local f; f=$(active_chat_file "$CHAT")
        [ -f "$f" ] && target=$(cat "$f")
      }
      [ -z "$target" ] && { send_tg "❌ usage: /watch off &lt;role/slug&gt;"; return; }
      local canon; canon=$(canonical_chat_from_target "$target")
      [ -z "$canon" ] && { send_tg "❌ ไม่เจอ chat <code>$target</code>"; return; }
      stop_watcher_for "$canon"
      send_tg "✓ watcher off for <code>$canon</code> (chat ยังอยู่ — push หยุด)"
      ;;
    all)
      recover_watchers
      send_tg "✓ ensured watchers for all live chats — /watch list ดู"
      ;;
    *)
      send_tg "usage: /watch [list|on|off|all] [&lt;role/slug&gt;]"
      ;;
  esac
}

cmd_history() {
  local tg_chat="$1" target="$2" n="${3:-20}"
  if [ -z "$target" ]; then
    local f; f=$(active_chat_file "$tg_chat")
    [ ! -f "$f" ] && { send_tg "❌ ไม่มี active chat — /chat ก่อน หรือ /history &lt;role/slug&gt;"; return; }
    target=$(cat "$f")
  fi
  # numeric arg means N when used after slash form
  case "$target" in [0-9]*) n="$target"; target=$(cat "$(active_chat_file "$tg_chat")" 2>/dev/null) ;; esac
  [ -z "$target" ] && { send_tg "❌ no active chat"; return; }
  local canon
  canon=$(canonical_chat_from_target "$target")
  [ -n "$canon" ] && target="$canon"
  local role="${target%%/*}" slug="${target#*/}" engine
  engine=$(get_chat_engine "$target")
  local repo; repo=$(role_repo "$role")
  [ -z "$repo" ] && { send_tg "❌ unknown role: $role"; return; }

  # Resolve the chat's actual worktree cwd from tmux pane (most reliable —
  # supports any worktree layout: maw's <repo>.wt-N-<slug>, claude code's
  # <repo>/.claude/worktrees/<name>, or vanilla <repo> for the oracle pane).
  # Fall back to repo dir if pane is dead.
  local cwd jsonl pane
  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  if [ "$engine" = "claude" ] && [ -n "$pane" ]; then
    local pane_cmd
    pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
    engine=$(detect_engine_from_cmd "$pane_cmd")
    set_chat_engine "$target" "$engine"
  fi
  if [ -n "$pane" ]; then
    cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
  fi
  [ -z "$cwd" ] && cwd="$repo"
  local turns
  if [ "$engine" = "codex" ]; then
    jsonl=$(find_codex_jsonl "$cwd")
    if [ -z "$jsonl" ] && [ "$slug" = "oracle" -o "$slug" = "main" ]; then
      jsonl=$(find_codex_jsonl "$repo")
    fi
    [ -z "$jsonl" ] && { send_tg "❌ ไม่เจอ codex session ของ <code>$target</code>
cwd ที่ลอง: <code>$cwd</code>"; return; }
    turns=$(jq -r '
      select(.type == "event_msg" and (.payload.type == "user_message" or .payload.type == "agent_message")) |
      if .payload.type == "user_message" then
        "[user] " + ((.payload.message // "")[0:400])
      else
        "[" + (.payload.phase // "assistant") + "] " + ((.payload.message // "")[0:400])
      end
    ' "$jsonl" 2>/dev/null | tail -"$n")
  else
    jsonl=$(find_jsonl "$cwd")
    if [ -z "$jsonl" ]; then
      # last resort: try old guess patterns for dead chats
      if [ "$slug" = "oracle" ] || [ "$slug" = "main" ]; then
        jsonl=$(find_jsonl "$repo")
      else
        local guess1 guess2
        guess1=$(ls -d "${repo}.wt-"*"-${slug}" 2>/dev/null | head -1)
        guess2="${repo}/.claude/worktrees/${slug}"
        [ -d "$guess1" ] && jsonl=$(find_jsonl "$guess1")
        [ -z "$jsonl" ] && [ -d "$guess2" ] && jsonl=$(find_jsonl "$guess2")
      fi
    fi
    [ -z "$jsonl" ] && { send_tg "❌ ไม่เจอ claude JSONL session ของ <code>$target</code>
cwd ที่ลอง: <code>$cwd</code>
encoded: <code>$(encode_cwd "$cwd")</code>"; return; }
    # Parse last N user/assistant turns. JSONL message.content can be:
    #   - string (simple message)
    #   - array of blocks: text / tool_use / tool_result / thinking
    # Filter to entries with non-empty text; skip pure tool/thinking rows.
    turns=$(jq -r '
      select(.type == "user" or .type == "assistant") |
      ((.message.content // "") |
        if type == "string" then .
        elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
        else "" end
      ) as $text |
      if ($text | length) > 0 then
        "[" + .type + "] " + ($text[0:400])
      else empty end
    ' "$jsonl" 2>/dev/null | tail -"$n")
  fi
  [ -z "$turns" ] && { send_tg "❌ history parse ว่าง — schema อาจต่างไป
file: $jsonl"; return; }
  send_tg "📜 <b>history</b> <code>$target</code> (engine=$engine, last $n turns):
<pre>$(echo "$turns" | html_escape)</pre>"
}

cmd_retro() {
  local role_filter="" n=5
  case "${1:-}" in
    "")          ;;
    [0-9]*)      n="$1" ;;
    *)           role_filter="$1"; [ -n "${2:-}" ] && n="$2" ;;
  esac
  case "$n" in all) n=999 ;; esac
  [ ! -d "$RETRO_ROOT" ] && { send_tg "❌ retro root ไม่เจอ: $RETRO_ROOT"; return; }
  local files
  files=$(find "$RETRO_ROOT" -name "*.md" -type f 2>/dev/null | sort -r | head -50)
  if [ -n "$role_filter" ]; then
    files=$(echo "$files" | grep -E "_${role_filter}|/${role_filter}|w[0-9]+-${role_filter}" | head -"$n")
  else
    files=$(echo "$files" | head -"$n")
  fi
  [ -z "$files" ] && { send_tg "❌ ไม่เจอ retro"; return; }
  local out="📓 <b>Retros</b>"
  [ -n "$role_filter" ] && out+=" (role=$role_filter)"
  out+=":

"
  while IFS= read -r f; do
    local rel="${f#$RETRO_ROOT/}"
    out+="• <code>$rel</code>
"
  done <<< "$files"
  send_tg "$out"
}

cmd_closed() {
  # Recently-ended chats: claude session JSONLs from worktrees that no longer
  # have a tmux pane. Looks at JSONL mtime in last 7 days as the activity signal.
  local out="🪦 <b>Recently-ended chats</b> (JSONL mtime < 7d, no live pane):

"
  local found=0
  for d in "$HOME/.claude/projects/"*; do
    [ ! -d "$d" ] && continue
    local proj=$(basename "$d")
    # only worktree projects: contain "-wt-N-"
    case "$proj" in *-wt-[0-9]*) ;; *) continue ;; esac
    # find latest JSONL mtime within 7 days
    local latest_jsonl
    latest_jsonl=$(find "$d" -name "*.jsonl" -mtime -7 2>/dev/null | head -1)
    [ -z "$latest_jsonl" ] && continue
    # extract the slug from project dir name (after last -wt-N-)
    local wt_part="${proj##*-wt-}"
    local slug="${wt_part#*-}"
    # check if any tmux pane has window matching *-${slug}
    if tmux list-panes -a -F "#{window_name}" 2>/dev/null | grep -qE "\\-${slug}\$"; then
      continue  # still alive, skip
    fi
    local age=$(printf '%s' "$(( ($(date +%s) - $(_mtime "$latest_jsonl" 2>/dev/null || echo 0)) / 60 ))min")
    out+="• <code>$slug</code> ($age ago, $proj)
"
    found=1
  done
  [ "$found" = "0" ] && out+="(ไม่มี ended chats ใน 7 วัน)"
  out+="

ใช้ /history &lt;role/slug&gt; ดูย้อน"
  send_tg "$out"
}

# ── /ctx — context window usage ───────────────────────────────────────────────

cmd_ctx() {
  local tg_chat="$1" target="${2:-}"
  if [ -z "$target" ]; then
    local f; f=$(active_chat_file "$tg_chat")
    [ ! -f "$f" ] && { send_tg "❌ ไม่มี active chat — /chat ก่อน หรือ /ctx &lt;role/slug&gt;"; return; }
    target=$(cat "$f")
  fi
  local canon
  canon=$(canonical_chat_from_target "$target")
  [ -n "$canon" ] && target="$canon"
  local role="${target%%/*}" slug="${target#*/}"
  local repo; repo=$(role_repo "$role")
  [ -z "$repo" ] && { send_tg "❌ unknown role: $role"; return; }

  local cwd pane jsonl engine
  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  engine=$(get_chat_engine "$target")
  if [ "$engine" = "claude" ] && [ -n "$pane" ]; then
    local pane_cmd
    pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
    engine=$(detect_engine_from_cmd "$pane_cmd")
    set_chat_engine "$target" "$engine"
  fi
  [ -n "$pane" ] && cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
  [ -z "$cwd" ] && cwd="$repo"
  local usage_all tokens out_tokens model effort max_ctx ctx_max raw_ctx effective_pct
  model=""
  effort=""
  raw_ctx=""
  effective_pct=""
  if [ "$engine" = "codex" ]; then
    jsonl=$(find_codex_jsonl "$cwd")
    if [ -z "$jsonl" ] && [ "$slug" = "oracle" -o "$slug" = "main" ]; then
      jsonl=$(find_codex_jsonl "$repo")
    fi
    [ -z "$jsonl" ] && { send_tg "❌ ไม่เจอ codex session ของ <code>$target</code>"; return; }
    usage_all=$(jq -r '
      select(.type == "event_msg" and .payload.type == "token_count") |
      [
        ((.payload.info.last_token_usage.input_tokens // 0) | tostring),
        ((.payload.info.last_token_usage.output_tokens // 0) | tostring),
        ((.payload.info.model_context_window // 0) | tostring)
      ] | join("\t")
    ' "$jsonl" 2>/dev/null)
    [ -z "$usage_all" ] && { send_tg "📊 <b>$target</b>: ยังไม่มี token_count ใน codex session นี้"; return; }
    local last_codex; last_codex=$(printf '%s' "$usage_all" | tail -1)
    tokens=$(printf '%s' "$last_codex" | cut -f1)
    out_tokens=$(printf '%s' "$last_codex" | cut -f2)
    ctx_max=$(printf '%s' "$last_codex" | cut -f3)
    [ -z "$ctx_max" ] || [ "$ctx_max" -le 0 ] && ctx_max=200000
    local pane_model cache_info
    pane_model=$(codex_pane_model_effort "$pane")
    model=$(printf '%s' "$pane_model" | awk '{print $1}')
    effort=$(printf '%s' "$pane_model" | awk '{print $2}')
    [ -z "$model" ] && model=$(codex_config_value model)
    [ -z "$effort" ] && effort=$(codex_config_value model_reasoning_effort)
    cache_info=$(codex_model_cache_info "$model")
    raw_ctx=$(printf '%s' "$cache_info" | cut -f1)
    effective_pct=$(printf '%s' "$cache_info" | cut -f2)
  else
    jsonl=$(find_jsonl "$cwd")
    [ -z "$jsonl" ] && { send_tg "❌ ไม่เจอ claude JSONL session ของ <code>$target</code>"; return; }
    # Single jq pass so input / output / model come from the same line.
    # Context window load = input_tokens + cache_creation_input_tokens + cache_read_input_tokens.
    usage_all=$(jq -r '
      select(.type == "assistant") |
      select(.message.usage.input_tokens != null) |
      [
        (((.message.usage.input_tokens // 0)
          + (.message.usage.cache_creation_input_tokens // 0)
          + (.message.usage.cache_read_input_tokens // 0)) | tostring),
        ((.message.usage.output_tokens // 0) | tostring),
        (.message.model // "")
      ] | join("\t")
    ' "$jsonl" 2>/dev/null)
    [ -z "$usage_all" ] && { send_tg "📊 <b>$target</b>: ยังไม่มีข้อมูล usage ใน session นี้"; return; }
    local last_line; last_line=$(printf '%s' "$usage_all" | tail -1)
    tokens=$(printf '%s' "$last_line" | cut -f1)
    out_tokens=$(printf '%s' "$last_line" | cut -f2)
    model=$(printf '%s' "$last_line" | cut -f3)
    # Context-window tier by model. The fleet launches `claude` with no --model,
    # so it inherits the account default — opus-4.6/4.7/4.8 and sonnet-4.x resolve
    # to the 1M variant. The JSONL usually records the model *without* the [1m]
    # suffix and carries no window field, so the name alone can't prove 1M — match
    # an explicit [1m]/-1m tag first, then map known-1M families by name. Anything
    # unrecognised (e.g. haiku) defaults to the standard 200k window.
    max_ctx=$(printf '%s' "$usage_all" | awk -F'\t' 'BEGIN{m=0} {if($1+0>m) m=$1+0} END{print m+0}')
    case "$model" in
      *\[1m\]|*-1m)                       ctx_max=1000000 ;;  # explicit 1M beta tag
      claude-opus-4-8*)                  ctx_max=1000000 ;;  # opus 4.8 → 1M default
      claude-opus-4-7*|claude-opus-4-6*) ctx_max=1000000 ;;
      claude-sonnet-4-*)                 ctx_max=1000000 ;;  # sonnet 1m default
      *)                                 ctx_max=200000 ;;
    esac
    # Safety floor: a session can never load more than its real window, so an
    # observed peak above the mapped tier proves a 1M window — bump to it.
    [ "$max_ctx" -gt "$ctx_max" ] && ctx_max=1000000
  fi

  local pct=$((tokens * 100 / ctx_max))
  local remaining=$((ctx_max - tokens))

  local filled=$((pct / 10)) i bar=""
  for i in $(seq 1 10); do
    [ "$i" -le "$filled" ] && bar="${bar}█" || bar="${bar}░"
  done

  local al; al=$(chat_alias "$target")
  [ -n "$al" ] && al=" ($al)"
  local model_line="" window_line="" ctx_label="$engine"
  if [ -n "$model" ]; then
    local model_display="$model"
    [ -n "$effort" ] && model_display="$model_display $effort"
    model_line="
model:  <code>$model_display</code>"
  fi
  if [ "$engine" = "codex" ]; then
    ctx_label="codex usable"
    if [ -n "$raw_ctx" ] && [ "$raw_ctx" -gt "$ctx_max" ] 2>/dev/null; then
      window_line="
window: <code>$ctx_max</code> usable / <code>$raw_ctx</code> raw${effective_pct:+ (${effective_pct}%)}"
    fi
  fi

  send_tg "📊 <b>${target}${al}</b>
${bar} <b>${pct}%</b>
ctx:    <code>$tokens</code> / <code>$ctx_max</code> (${ctx_label})${out_tokens:+    output: <code>$out_tokens</code>}
left:   <code>$remaining</code> tokens${model_line}${window_line}"
}

# ── /quota — Claude Code usage window / reset estimate ────────────────────────

cmd_quota() {
  local tg_chat="$1"
  # Claude Code's 5h rolling window starts at the first API call after a reset.
  # Best proxy: find the oldest first-message timestamp across all active sessions
  # that falls within the last 5h — that's when the current window likely opened.
  # Sessions older than 5h don't constrain the window (it already reset after them).
  local now; now=$(date +%s)
  local oldest_in_window=0  # epoch of earliest session within last 5h
  local session_lines="" role
  while IFS= read -r role; do
    while IFS='|' read -r pane _s _w _cmd slug; do
      [ -z "$pane" ] || [ -z "$slug" ] && continue
      local chat="$role/$slug"
      local cwd; cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
      [ -z "$cwd" ] && continue
      local engine; engine=$(get_chat_engine "$chat")
      [ "$engine" = "claude" ] && engine=$(detect_engine_from_cmd "$_cmd")
      local j
      if [ "$engine" = "codex" ]; then
        j=$(find_codex_jsonl "$cwd")
      else
        j=$(find_jsonl "$cwd")
      fi
      [ -z "$j" ] && continue
      local first_ts
      if [ "$engine" = "codex" ]; then
        first_ts=$(jq -r 'select(.type == "session_meta") | (.payload.timestamp // .timestamp)' "$j" 2>/dev/null | head -1)
      else
        first_ts=$(jq -r 'select(.timestamp) | .timestamp' "$j" 2>/dev/null | head -1)
      fi
      [ -z "$first_ts" ] && continue
      # JSONL timestamps are UTC (ISO 8601 with Z suffix). Parse with -u so
      # we don't add the local timezone offset (would show +7h on GMT+7).
      local ts_s="${first_ts%%.*}"  # strip fractional seconds, keep T
      local epoch; epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ts_s" "+%s" 2>/dev/null)
      [ -z "$epoch" ] && continue
      local age_m=$(( (now - epoch) / 60 ))
      local al; al=$(chat_alias "$chat")
      [ -n "$al" ] && al=" ($al)"
      if [ "$age_m" -lt 300 ]; then
        session_lines+="• <code>${chat}${al}</code>: started ${age_m}m ago (in window, ${engine})
"
        [ "$epoch" -lt "$oldest_in_window" ] || [ "$oldest_in_window" -eq 0 ] && oldest_in_window=$epoch
      else
        local h=$(( age_m / 60 )) m=$(( age_m % 60 ))
        session_lines+="• <code>${chat}${al}</code>: ${h}h ${m}m old (outside window, ${engine})
"
      fi
    done <<< "$(chats_for_role "$role")"
  done <<< "$(all_roles)"

  local out=""
  if [ "$oldest_in_window" -gt 0 ]; then
    local window_age_m=$(( (now - oldest_in_window) / 60 ))
    local reset_in_m=$(( 300 - window_age_m ))
    out="⏱ <b>Quota window</b>: opened ${window_age_m}m ago → resets in ~<b>${reset_in_m}m</b>
"
  else
    out="⏱ <b>Quota window</b>: ไม่มี session ในช่วง 5h — quota น่าจะ reset แล้ว
"
  fi
  [ -n "$session_lines" ] && out+="
${session_lines}"
  send_tg "$out"
}

# ── send to active chat ────────────────────────────────────────────────────

cmd_send_to_chat() {
  local tg_chat="$1" text="$2"
  local f; f=$(active_chat_file "$tg_chat")
  [ ! -f "$f" ] && { send_tg "❌ ไม่มี active chat — /chat &lt;role&gt; ก่อน หรือ /help"; return; }
  local target pane
  target=$(cat "$f")
  # If this chat has a live AskUserQuestion and the text is "2,2"-style (one
  # number per question), treat it as the answer set and drive the TUI instead
  # of typing into the agent's input field.
  local _safe; _safe=$(echo "$target" | tr '/' '_')
  local _pend="$STATE_DIR/ask-pending.$_safe"
  if [ -s "$_pend" ] && printf '%s' "$text" | grep -qE '^[0-9]+([,[:space:]]+[0-9]+)*$'; then
    local _nq _nums _cnt; _nq=$(cut -d'|' -f2 "$_pend")
    _nums=$(printf '%s' "$text" | grep -oE '[0-9]+'); _cnt=$(printf '%s\n' "$_nums" | grep -c .)
    if [ "$_cnt" = "$_nq" ]; then
      local _ans="$STATE_DIR/ask-answers.$_safe"; : > "$_ans"; local _qi=0 _n
      for _n in $_nums; do echo "$_qi $((_n-1))" >> "$_ans"; _qi=$((_qi+1)); done
      tui_ask_submit "$target" "$_ans" "$_nq"
      rm -f "$_pend" "$_ans" "$STATE_DIR/ask-last.$_safe"
      return
    fi
  fi
  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  # Pane not resolvable right now — could be transient (agent shelled out to a
  # foreground cmd, tmux mid-rebuild) OR genuinely gone. Do NOT delete the
  # active-chat marker: it is the user's intent and a single flaky lookup was
  # silently unbinding them, forcing /chat on every return. Keep it sticky;
  # only /chat, /end, /close change it. Tell them it's unreachable + how to act.
  [ -z "$pane" ] && { send_tg "⚠️ active chat <code>$target</code> ส่งไม่ได้ตอนนี้ (pane ไม่เจอ — agent อาจกำลังรันคำสั่ง หรือเพิ่งปิด). binding ยังอยู่ — ลองใหม่อีกครั้ง, หรือ <code>/relaunch $target</code>, หรือ <code>/end</code> เพื่อล้าง"; return; }
  audit "→ chat=$target pane=$pane text=$text"
  # Refuse if no agent CLI is running in the pane — text would land in zsh and
  # never reach the agent. Observed 2026-05-01 after pg-tester's `claude -p`
  # exited and the user typed via brewbot, producing zsh "command not found"
  # for every Thai message until they noticed.
  local pane_cmd
  pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
  if ! is_agent_cmd "$pane_cmd"; then
    send_tg "❌ ไม่มี agent CLI รันใน <code>$target</code> (pane cmd=<code>${pane_cmd:-?}</code>) — ข้อความจะตกใน shell, ไม่ส่งให้
รีเริ่ม: <code>/relaunch</code> (active chat) หรือ <code>/relaunch $target</code>"
    return
  fi
  # Mark "user just sent" so the watcher's quiet-window kicks in (avoids
  # auto-pushing back the user's own message + claude's first ack burst).
  date +%s > "$(user_send_marker "$target")"
  # Deliver the message the way a human paste does — atomically, not key-by-key.
  # The old `send-keys -- "$text"` typed each char into the TUI, racing claude's
  # async multi-byte (Thai) rendering: Enter could fire before the field caught
  # up → text dropped or stuck unsubmitted, or fast retypes concatenated onto a
  # half-typed leftover (the "ติด TUI" the user kept hitting). Instead:
  #   1. C-u clears any half-typed leftover so nothing concatenates.
  #   2. Paste the whole string via a named BRACKETED-paste buffer — multi-byte
  #      and multi-line land intact in one shot, and bracketed mode stops an
  #      embedded newline from submitting early.
  #   3. Let the TUI settle, then Enter on its own to submit.
  tmux send-keys -t "$pane" C-u 2>/dev/null                       # clear input field
  tmux set-buffer -b brewbot_send -- "$text" 2>/dev/null
  tmux paste-buffer -t "$pane" -b brewbot_send -p -d 2>/dev/null  # -p bracketed, -d drop buffer
  sleep 0.3
  tmux send-keys -t "$pane" Enter 2>/dev/null
  send_tg "→ <code>$target</code> sent. 🔔 watcher จะ push ตอน agent ตอบเสร็จ"
}

# ── send TUI navigation keys to a chat's pane ───────────────────────────────
# For when an agent is stuck in a TUI selection (e.g. claude's permission menu)
# and a plain message can't drive it — send Up/Down to highlight, Enter to pick.
# Navigation only (no ctrl combos), so a stray /key can never kill an agent.
# Friendly alias → tmux key name; each token may carry a *N repeat (down*3).
# Default target = active chat; a role/slug first arg overrides it.
key_alias() {
  case "$1" in
    up)              echo Up ;;
    down)            echo Down ;;
    left)            echo Left ;;
    right)           echo Right ;;
    enter|cr|return) echo Enter ;;
    esc|escape)      echo Escape ;;
    tab)             echo Tab ;;
    space)           echo Space ;;
    bs|backspace)    echo BSpace ;;
    pgup|pageup)     echo PageUp ;;
    pgdn|pagedown)   echo PageDown ;;
    home)            echo Home ;;
    end)             echo End ;;
    y|n|[0-9])       echo "$1" ;;
    *)               echo "" ;;
  esac
}

KEY_USAGE='usage: <code>/key [role/slug] &lt;keys…&gt;</code>
คีย์: up down left right enter esc tab space pgup pgdn home end y n 0-9 (ซ้ำ: <code>down*3</code>)
เช่น <code>/key down down enter</code> · <code>/key down*2 enter</code> · <code>/key esc</code>'

# TUI-menu pick: the watcher pushed a `❯ N.` selection menu as inline buttons;
# a tap arrives here as callback_data "pick:<role/slug>:<n>". Drive the pane to
# option N and confirm — deterministically, by re-reading the live cursor
# position (don't assume it sits on option 1) and stepping with Down/Up + Enter.
cmd_pick() {
  local arg="$1"                       # <role/slug>:<n>
  local n="${arg##*:}" chat="${arg%:*}"
  case "$n" in ''|*[!0-9]*) send_tg "❌ pick: ตัวเลือกไม่ถูกต้อง"; return ;; esac
  local pane; pane=$(resolve_chat "$chat" | cut -d'|' -f1)
  [ -z "$pane" ] && { send_tg "⚠️ <code>$chat</code> หา pane ไม่เจอ — เมนูอาจปิดไปแล้ว"; return; }
  local snap; snap=$(tmux capture-pane -t "$pane" -p 2>/dev/null)
  if ! printf '%s' "$snap" | grep -qE '^[[:space:]]*❯[[:space:]]*[0-9]+\.'; then
    send_tg "⚠️ <code>$chat</code> ไม่มีเมนูให้เลือกแล้ว (agent อาจตอบไปแล้ว)"; return
  fi
  local cur; cur=$(printf '%s' "$snap" | grep -E '^[[:space:]]*❯[[:space:]]*[0-9]+\.' \
    | head -1 | sed -E 's/^[[:space:]]*❯[[:space:]]*([0-9]+)\..*/\1/')
  [ -z "$cur" ] && cur=1
  local delta=$(( n - cur )) i
  if [ "$delta" -gt 0 ]; then
    for ((i=0; i<delta; i++)); do tmux send-keys -t "$pane" Down 2>/dev/null; sleep 0.1; done
  elif [ "$delta" -lt 0 ]; then
    for ((i=0; i<-delta; i++)); do tmux send-keys -t "$pane" Up 2>/dev/null; sleep 0.1; done
  fi
  sleep 0.2
  tmux send-keys -t "$pane" Enter 2>/dev/null
  audit "pick chat=$chat pane=$pane option=$n (cursor was $cur)"
  send_tg "✅ <code>$chat</code> เลือกข้อ <b>$n</b> แล้ว 🔔 watcher จะ push คำตอบต่อ"
}

# AskUserQuestion option tapped: callback "ask:<role/slug>:<qi>:<oi>" (0-indexed).
# The watcher pushed one button per option across N questions; we accumulate one
# answer per question and only drive+submit once every question is answered.
cmd_ask() {
  local arg="$1"                          # <role/slug>:<qi>:<oi>
  local oi="${arg##*:}" rest qi chat
  rest="${arg%:*}"; qi="${rest##*:}"; chat="${rest%:*}"
  case "$qi$oi" in ''|*[!0-9]*) send_tg "❌ ask: ค่าเพี้ยน"; return ;; esac
  local safe; safe=$(echo "$chat" | tr '/' '_')
  local pend="$STATE_DIR/ask-pending.$safe" ans="$STATE_DIR/ask-answers.$safe"
  [ ! -s "$pend" ] && { send_tg "⚠️ <code>$chat</code> ไม่มีเมนูค้างแล้ว (อาจตอบไปแล้ว/เปลี่ยนคำถาม)"; return; }
  local nq; nq=$(cut -d'|' -f2 "$pend")
  # Record (overwrite) this question's choice, keep answers ordered by question.
  { grep -v "^$qi " "$ans" 2>/dev/null; echo "$qi $oi"; } | sort -n > "$ans.tmp" && mv "$ans.tmp" "$ans"
  local got; got=$(grep -c . "$ans" 2>/dev/null)
  if [ "$got" -lt "$nq" ]; then
    send_tg "✔️ <code>$chat</code> Q$((qi+1))=ข้อ$((oi+1)) — ตอบครบ <b>$got/$nq</b> แล้ว เลือกที่เหลือต่อ"
    return
  fi
  tui_ask_submit "$chat" "$ans" "$nq"
  rm -f "$pend" "$ans" "$STATE_DIR/ask-last.$safe"
}

# Drive an AskUserQuestion TUI from the collected answers. Per the menu footer
# ("Enter to select · Tab/Arrow keys to navigate"): step Down within a question
# to the chosen option (cursor starts at option 1), Tab to the next question,
# and Enter once to submit all. NOTE: this key model is best-effort — validate
# on a live, responsive menu; if it ever drifts, answer in the pane.
tui_ask_submit() {
  local chat="$1" ans="$2" nq="$3" pane qi oi i first=1
  pane=$(resolve_chat "$chat" | cut -d'|' -f1)
  [ -z "$pane" ] && { send_tg "⚠️ <code>$chat</code> หา pane ไม่เจอ — ส่งคำตอบไม่ได้"; return; }
  while read -r qi oi; do
    [ "$first" = 1 ] || tmux send-keys -t "$pane" Tab 2>/dev/null
    first=0; sleep 0.15
    for ((i=0; i<oi; i++)); do tmux send-keys -t "$pane" Down 2>/dev/null; sleep 0.1; done
  done < "$ans"
  sleep 0.2
  tmux send-keys -t "$pane" Enter 2>/dev/null
  local summary; summary=$(awk '{printf "Q%d=ข้อ%d ", $1+1, $2+1}' "$ans")
  audit "ask-submit chat=$chat pane=$pane [$summary]"
  send_tg "✅ <code>$chat</code> ส่งคำตอบแล้ว: <b>$summary</b>🔔 watcher จะ push ผลต่อ"
}

# ── TUI remote control ──────────────────────────────────────────────────────
# The watcher pushes a live menu snapshot + this keyboard; each tap drives the
# pane and edits the message in place. Mirrors chat-watcher's menu_remote_kbd.
nav_keyboard() {
  local c="$1"
  printf '{"inline_keyboard":[[{"text":"⬆️","callback_data":"nav:%s:up"},{"text":"⬇️","callback_data":"nav:%s:down"}],[{"text":"✅ ติ๊ก/เลือก","callback_data":"nav:%s:enter"},{"text":"⏎ Enter","callback_data":"nav:%s:enter"}],[{"text":"📤 Submit","callback_data":"nav:%s:submit"},{"text":"❌ ยกเลิก(Esc)","callback_data":"nav:%s:esc"}]]}' "$c" "$c" "$c" "$c" "$c" "$c"
}

# Move the ❯ cursor onto the "Submit" row, then Enter. Step Down one at a time
# and check after EACH step whether the cursor line now contains "Submit" — match
# on "the ❯ line contains Submit" (robust to spacing/checkbox rendering) rather
# than a strict "❯ Submit" regex, which silently missed and spammed Down without
# ever submitting. Bounded; if Submit never lands under the cursor, give up so
# the caller can tell the user to reach it with ⬇️ + ✅ instead.
tui_goto_submit() {
  local pane="$1" i cur
  for ((i=0; i<12; i++)); do
    cur=$(tmux capture-pane -p -t "$pane" 2>/dev/null | grep -E '^[[:space:]]*❯' | head -1)
    if printf '%s' "$cur" | grep -q 'Submit'; then
      tmux send-keys -t "$pane" Enter 2>/dev/null; return 0
    fi
    tmux send-keys -t "$pane" Down 2>/dev/null; sleep 0.25
  done
  return 1
}

# Edit a menu message in place (text + same keyboard).
edit_menu_message() {
  local msg="$1" text="$2" kbd="$3"
  [ -z "$msg" ] && return
  curl -sf "https://api.telegram.org/bot${TOKEN}/editMessageText" \
    --data-urlencode "chat_id=$CHAT" \
    --data-urlencode "message_id=$msg" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$text" \
    --data-urlencode "reply_markup=$kbd" -o /dev/null 2>/dev/null
}

# A TUI remote-control button was tapped — callback "nav:<role/slug>:<key>".
# Send the key to the pane, re-capture, and edit the message so the cursor /
# checkboxes update live. Works for single- and multi-select (Submit) menus.
cmd_nav() {
  local arg="$1" msg="$2"            # arg = <role/slug>:<key>
  local key="${arg##*:}" chat="${arg%:*}"
  local pane; pane=$(resolve_chat "$chat" | cut -d'|' -f1)
  [ -z "$pane" ] && { send_tg "⚠️ <code>$chat</code> หา pane ไม่เจอ — เมนูอาจปิดแล้ว"; return; }
  case "$key" in
    up)     tmux send-keys -t "$pane" Up 2>/dev/null ;;
    down)   tmux send-keys -t "$pane" Down 2>/dev/null ;;
    enter)  tmux send-keys -t "$pane" Enter 2>/dev/null ;;
    esc)    tmux send-keys -t "$pane" Escape 2>/dev/null ;;
    submit) tui_goto_submit "$pane" || send_tg "⚠️ หา Submit ไม่เจอ — ใช้ ⬇️ + ✅ เอง" ;;
    *) return ;;
  esac
  audit "nav chat=$chat key=$key pane=$pane"
  sleep 0.35
  local snap; snap=$(tmux capture-pane -p -t "$pane" 2>/dev/null | grep -vE '^[[:space:]]*$' | tail -22 | html_escape)
  [ -z "$snap" ] && snap="(จอว่าง — เมนูอาจปิดแล้ว)"
  edit_menu_message "$msg" "🎮 <code>$chat</code> เมนู TUI:
<pre>${snap}</pre>" "$(nav_keyboard "$chat")"
}

cmd_key() {
  local tg_chat="$1"; shift
  local target pane
  case "${1:-}" in
    */*) target="$1"; shift ;;                       # explicit role/slug
    *)
      local f; f=$(active_chat_file "$tg_chat")
      [ ! -f "$f" ] && { send_tg "❌ ไม่มี active chat — /chat &lt;role&gt; ก่อน หรือระบุ target: <code>/key &lt;role/slug&gt; &lt;keys&gt;</code>"; return; }
      target=$(cat "$f") ;;
  esac
  [ "$#" -eq 0 ] && { send_tg "$KEY_USAGE"; return; }

  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  [ -z "$pane" ] && { send_tg "❌ ไม่เจอ pane ของ <code>$target</code> (chat ตาย/ชื่อกำกวม) — /chats ดู"; return; }

  # Expand tokens → tmux keys; reject any unknown token up-front so we never
  # send a partial sequence into the wrong place.
  local -a keys=(); local tok base rep k i
  for tok in "$@"; do
    base="${tok%%\**}"; rep="${tok#*\*}"
    [ "$rep" = "$tok" ] && rep=1                      # no '*' → once
    case "$rep" in ""|*[!0-9]*) rep=1 ;; esac
    [ "$rep" -lt 1 ] && rep=1
    [ "$rep" -gt 20 ] && rep=20                       # cap runaway repeats
    k=$(key_alias "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')")
    [ -z "$k" ] && { send_tg "❌ ปุ่มไม่รู้จัก: <code>$base</code>
$KEY_USAGE"; return; }
    for ((i=0; i<rep; i++)); do keys+=("$k"); done
  done

  local pane_cmd; pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
  # Mark user-send so the watcher's quiet window suppresses echo of our own keys.
  date +%s > "$(user_send_marker "$target")"
  # One key per send-keys with a short gap; Enter gets a longer lead so the TUI
  # commits the highlighted item before we confirm (same rationale as text path).
  for k in "${keys[@]}"; do
    if [ "$k" = "Enter" ]; then sleep 0.3; else sleep 0.05; fi
    tmux send-keys -t "$pane" "$k" 2>/dev/null
  done
  audit "→ key chat=$target pane=$pane keys=${keys[*]}"
  send_tg "⌨️ <code>$target</code> ← <code>${keys[*]}</code> (pane=<code>${pane_cmd:-?}</code>)"
}

# ── dispatcher ─────────────────────────────────────────────────────────────

dispatch() {
  local chat_id="$1" text="$2"
  if [ "$chat_id" != "$CHAT" ]; then log "ignored chat=$chat_id"; return; fi
  audit "[chat=$chat_id] $text"
  set -- $text
  case "$1" in
    /help|/start) cmd_help ;;
    /blockers)    cmd_blockers ;;
    /pending)     cmd_pending ;;
    /threads)     cmd_threads "${2:-all}" ;;
    /list)        cmd_list ;;
    /roles)       cmd_roles ;;
    /chats)       cmd_chats "${2:-}" ;;
    /chat)        cmd_chat "$chat_id" "${2:-}" ;;
    /alias)       cmd_alias "$chat_id" "${2:-}" "${3:-}" ;;
    /new)         cmd_new "$chat_id" "${2:-}" "${3:-}" "${4:-}" ;;
    /relaunch)    cmd_relaunch "$chat_id" "${2:-}" ;;
    /close)       cmd_close "${2:-}" "${3:-}" ;;
    /look)        cmd_look "$chat_id" "${2:-25}" ;;
    /key)         shift; cmd_key "$chat_id" "$@" ;;
    /end)         cmd_end "$chat_id" ;;
    /watch)       cmd_watch "${2:-list}" "${3:-}" ;;
    /history)     cmd_history "$chat_id" "${2:-}" "${3:-20}" ;;
    /retro)       cmd_retro "${2:-}" "${3:-}" ;;
    /closed)      cmd_closed ;;
    /ctx)         cmd_ctx "$chat_id" "${2:-}" ;;
    /quota)       cmd_quota "$chat_id" ;;
    /*)           send_tg "❌ unknown command — /help" ;;
    *)            cmd_send_to_chat "$chat_id" "$text" ;;
  esac
}

# Find other live supervisors of THIS script (singleton guard). Keys on
# parent-dir + basename ("brew-ops-bot/bot.sh") so we never cross-kill
# orchestrator-bot. Children of the current process (curl getUpdates,
# subshells) are excluded via the PPID guard — they share the script name
# but are not supervisors.
find_other_daemons() {
  local key
  key=$(basename "$(dirname "$0")")/$(basename "$0")
  local p ppid cmd out=""
  for p in $(pgrep -f "$key" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    ppid=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
    [ "$ppid" = "$$" ] && continue   # skip own subprocesses
    cmd=$(ps -p "$p" -o command= 2>/dev/null)
    case "$cmd" in *"$key"*) out="$out $p" ;; esac
  done
  echo "${out# }"
}

# ── main ───────────────────────────────────────────────────────────────────

main() {
  log "brew-ops-bot starting (pid=$$, chat-whitelist=$CHAT)"
  trap 'log "shutting down (pid=$$)"; exit 0' INT TERM
  # Phase 4 v2: scan existing chats and spawn watchers (recover after restart)
  recover_watchers
  # Refresh pinned status message so it reflects current state on boot
  update_status "$CHAT"
  local last_id=0
  [ -f "$LAST_UPDATE_ID_FILE" ] && last_id=$(cat "$LAST_UPDATE_ID_FILE")
  local last_recover; last_recover=$(date +%s)  # boot recover_watchers just ran
  while true; do
    # Periodic backstop: respawn any chat-watcher that bailed mid-session.
    # The boot-time recover_watchers runs once; this re-runs it every
    # WATCHER_RECOVER_INTERVAL so a watcher that exited (e.g. engine cold-start
    # exceeded JSONL_WAIT_SECONDS) is picked back up without a bot restart.
    if [ "${WATCHER_RECOVER_INTERVAL:-0}" -gt 0 ] && \
       [ "$(( $(date +%s) - last_recover ))" -ge "$WATCHER_RECOVER_INTERVAL" ]; then
      reap_orphan_watchers   # reap before respawn so we don't double-spawn live ones
      recover_watchers
      last_recover=$(date +%s)
    fi
    local resp
    resp=$(curl -sf --max-time 35 "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=$((last_id + 1))&timeout=30" 2>/dev/null) || { sleep 5; continue; }
    local n; n=$(echo "$resp" | jq '.result | length' 2>/dev/null)
    [ "${n:-0}" -eq 0 ] && continue
    for i in $(seq 0 $((n - 1))); do
      local update_id chat_id text cb_id cb_data cb_chat
      update_id=$(echo "$resp" | jq ".result[$i].update_id")
      last_id=$update_id
      echo "$last_id" > "$LAST_UPDATE_ID_FILE"

      # Inline keyboard tap → callback_query (separate from regular message)
      cb_id=$(echo "$resp" | jq -r ".result[$i].callback_query.id // empty")
      if [ -n "$cb_id" ]; then
        cb_data=$(echo "$resp" | jq -r ".result[$i].callback_query.data // empty")
        cb_chat=$(echo "$resp" | jq -r ".result[$i].callback_query.message.chat.id // empty")
        cb_msg=$(echo "$resp" | jq -r ".result[$i].callback_query.message.message_id // empty")
        ack_callback "$cb_id"
        # Translate callback_data → command. Format: "<action>:<arg>"
        case "$cb_data" in
          chat:*)   dispatch "$cb_chat" "/chat ${cb_data#chat:}" ;;
          close:*)  dispatch "$cb_chat" "/close ${cb_data#close:}" ;;
          chats:*)  dispatch "$cb_chat" "/chats ${cb_data#chats:}" ;;
          watch_off:*) dispatch "$cb_chat" "/watch off ${cb_data#watch_off:}" ;;
          pick:*)   cmd_pick "${cb_data#pick:}" ;;   # TUI-menu option tapped
          ask:*)    cmd_ask "${cb_data#ask:}" ;;     # AskUserQuestion option tapped
          nav:*)    cmd_nav "${cb_data#nav:}" "$cb_msg" ;;  # TUI remote-control key
          *)        log "unhandled callback: $cb_data" ;;
        esac
        continue
      fi

      # Regular text message
      chat_id=$(echo "$resp" | jq ".result[$i].message.chat.id // empty")
      text=$(echo "$resp" | jq -r ".result[$i].message.text // empty")
      [ -z "$chat_id" ] || [ -z "$text" ] && continue
      dispatch "$chat_id" "$text"
    done
  done
}

case "${1:-loop}" in
  loop|start)
    others=$(find_other_daemons)
    if [ -n "$others" ]; then
      echo "another $(basename "$0") is already running (pid=$others)" >&2
      echo "stop it first: $0 stop  (or: kill $others)" >&2
      exit 1
    fi
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "already running: $(cat "$PID_FILE")" >&2
      exit 1
    fi
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"' EXIT
    trap 'rm -f "$PID_FILE"; exit 0' INT TERM
    main
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
  restart)
    "$0" stop
    sleep 1
    exec "$0" start
    ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "running: pid=$(cat "$PID_FILE")"
    else
      echo "stopped"
    fi
    ;;
  test-send)
    send_tg "${2:-test from brew-ops-bot}"
    ;;
  *)
    cat <<USAGE >&2
usage: $0 {loop|start|stop|restart|status|test-send <msg>}
USAGE
    exit 2
    ;;
esac

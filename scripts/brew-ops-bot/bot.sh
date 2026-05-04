#!/usr/bin/env bash
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
AUDIT_FILE=$STATE_DIR/audit.log
LAST_UPDATE_ID_FILE=$STATE_DIR/last-update-id
ACTIVE_CHAT_FILE_PREFIX=$STATE_DIR/active-chat

# Repos in scope for blockers/pending markers + orphan-worktree sweep.
# Populated at boot by load_roles from fleet configs — every repo with at
# least one fleet-registered role becomes scope-eligible. Adding a fleet
# json (user-level or .agent/fleet/) auto-extends scope; no code change.
REPOS=()
ORACLE_DB=$HOME/.arra-oracle-v2/oracle.db
SQLITE=$(command -v sqlite3 || echo /usr/bin/sqlite3)
RETRO_ROOT=$HOME/.arra-oracle-v2/ψ/memory/retrospectives

# Role registry — loaded dynamically from maw fleet configs at boot.
# Format per entry: <role>|<session>|<repo-path>
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
    while IFS= read -r win; do
      [ -z "$win" ] && continue
      local role="${win%-oracle}"
      # dedupe: only first occurrence wins
      case "|$seen|" in *"|$role|"*) continue ;; esac
      seen+="|$role"
      ROLES+=("${role}|${session}|${repo_path}")
    done < <(jq -r '.windows[].name // empty' "$f" 2>/dev/null)
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

# ── helpers ────────────────────────────────────────────────────────────────

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
audit() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$AUDIT_FILE"; }

# HTML-escape dynamic content before embedding in send_tg's parse_mode=HTML.
html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

send_tg() {
  local text="$1" markup="${2:-}"
  if [ ${#text} -gt 3900 ]; then text="${text:0:3850}

[…truncated]"; fi
  local args=(
    --data-urlencode "chat_id=$CHAT"
    --data-urlencode "parse_mode=HTML"
    --data-urlencode "text=$text"
  )
  [ -n "$markup" ] && args+=(--data-urlencode "reply_markup=$markup")
  local resp
  resp=$(curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" "${args[@]}" 2>&1)
  if [ -z "$resp" ] || ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
    log "send_tg failed: $(echo "$resp" | head -c 300)"
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

# Path to the chat-watcher script (sibling file, same dir).
SCRIPT_DIR_BOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR_BOT/chat-watcher.sh"

# Phase 4 helpers — auto-push agent output to Telegram when claude stabilizes.
watch_pid_file() { echo "$STATE_DIR/watch.$(echo "$1" | tr '/' '_').pid"; }
user_send_marker() { echo "$STATE_DIR/last-user-send.$(echo "$1" | tr '/' '_')"; }

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
  local pane="$1" chat_id="$2"
  stop_watcher_for "$chat_id"  # idempotent — kill any prior watcher first
  if [ ! -x "$WATCHER_SCRIPT" ]; then
    log "watcher script not executable: $WATCHER_SCRIPT"
    return
  fi
  nohup bash "$WATCHER_SCRIPT" "$pane" "$chat_id" </dev/null >/dev/null 2>&1 &
  disown
}

# Boot recovery: scan all live chats and spawn watchers that aren't running.
# Called once on bot startup so chats survive a bot restart with auto-push intact.
recover_watchers() {
  local role
  while IFS= read -r role; do
    while IFS='|' read -r pane sess win cmd slug; do
      [ -z "$pane" ] && continue
      local chat="$role/$slug"
      local pf; pf=$(watch_pid_file "$chat")
      if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
        continue  # already running
      fi
      log "recover_watchers: spawning watcher for $chat ($pane)"
      start_watcher_for "$pane" "$chat"
    done <<< "$(chats_for_role "$role")"
  done <<< "$(all_roles)"
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
all_roles() { for line in "${ROLES[@]}"; do echo "$line" | cut -d'|' -f1; done; }

# Enumerate chats for a role: every tmux pane whose window_name starts with
# "<role>-". Returns lines: <pane_id>|<session>|<window>|<cmd>|<slug>
chats_for_role() {
  local role="$1"
  tmux list-panes -a -F "#{pane_id}|#{session_name}|#{window_name}|#{pane_current_command}" 2>/dev/null \
    | awk -F'|' -v p="${role}-" 'index($3, p) == 1 { slug=substr($3, length(p)+1); print $0 "|" slug }'
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
/new &lt;role&gt; [slug]        spawn new chat (uses maw wake)
/relaunch [role/slug]     restart claude in existing pane (after -p exit)
/close &lt;role/slug&gt;        kill chat (pane + leaves worktree orphan)
/close all [auto]         audit + close safe chats; sweep orphan wt/aliases

<b>Active chat I/O:</b>
&lt;plain msg&gt;               → send to current chat
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
      is_claude "$cmd" && active=$((active + 1))
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
      local marker; is_claude "$cmd" && marker="✅" || marker="⚪"
      out+="$marker <code>$role/$slug</code> $pane (cmd=$cmd)
"
      found=1
    done <<< "$(chats_for_role "$role")"
  done <<< "$(all_roles)"
  [ "$found" = "0" ] && out+="(ยังไม่มี chats)"
  out+="

✅=claude alive  ⚪=zsh idle"
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
  echo "$role/$slug" > "$(active_chat_file "$tg_chat")"
  # Phase 4 v2: each chat has its own watcher (independent of active context).
  # /chat just routes plain messages — doesn't toggle the watcher.
  # If pane's watcher isn't running (e.g. after bot restart), spawn it.
  if [ ! -f "$(watch_pid_file "$role/$slug")" ] || ! kill -0 "$(cat "$(watch_pid_file "$role/$slug")" 2>/dev/null)" 2>/dev/null; then
    start_watcher_for "$pane" "$role/$slug"
  fi
  local al; al=$(chat_alias "$role/$slug")
  local al_label; [ -n "$al" ] && al_label=" (<b>$al</b>)" || al_label=""
  send_tg "✓ active chat: <code>$role/$slug</code>${al_label} ($pane, cmd=$cmd)
ส่งข้อความตอนนี้ → ไป chat นี้
/watch ดู watcher status, /look /history ดูเนื้อหา"
  update_status "$tg_chat"
}

cmd_new() {
  local tg_chat="$1" role="$2" slug="${3:-$(date +%Y%m%d-%H%M%S)}"
  [ -z "$role" ] && { send_tg "❌ usage: /new &lt;role&gt; [slug]"; return; }
  local repo
  repo=$(role_repo "$role")
  [ -z "$repo" ] && { send_tg "❌ unknown role: $role (ใช้ /roles)"; return; }
  audit "/new $role $slug"

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

  # maw wake creates worktree + pane. Without --task it leaves zsh prompt;
  # we send `claude --dangerously-skip-permissions` afterward to start
  # interactive claude in the new pane.
  local out
  out=$(maw wake "$role" --wt "$slug" --fresh 2>&1 | tail -8)
  log "/new $role/$slug — maw wake output: $out"
  sleep 2
  # find the pane maw created
  local pane
  pane=$(tmux list-panes -a -F "#{pane_id}|#{window_name}" 2>/dev/null | awk -F'|' -v w="${role}-${slug}" '$2==w{print $1; exit}')
  if [ -z "$pane" ]; then
    send_tg "❌ pane <code>${role}-${slug}</code> ไม่ถูกสร้าง — ดู maw output:
<pre>$(echo "$out" | html_escape)</pre>"
    return
  fi
  # Maw's send-keys template (`claude --continue || claude -p '<task>'`) often
  # already starts an interactive claude in fresh worktrees — `--continue`
  # silently opens a new session even with no prior conversation. So we MUST
  # NOT blindly send-keys our own `claude --dangerously...` line; if claude is
  # already up, that text would land inside claude's input box as a "user
  # message" and trigger a response (observed 2026-04-28: brew-ops/20260428-195326
  # got "That's the Claude Code CLI flag..." spurious turn).
  #
  # Wait for maw's template to settle, then check pane_current_command:
  #   - shell (zsh/bash/sh/fish) → maw didn't start claude → start it ourselves
  #   - claude version (e.g. 2.1.119) → maw started it → leave alone
  sleep 3
  local pane_cmd
  pane_cmd=$(tmux list-panes -t "$pane" -F "#{pane_current_command}" 2>/dev/null | head -1)
  if echo "$pane_cmd" | grep -qE '^(zsh|bash|sh|fish)$'; then
    log "/new $role/$slug — pane at $pane_cmd, starting claude"
    tmux send-keys -t "$pane" -- "claude --dangerously-skip-permissions" 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$pane" Enter 2>/dev/null
    sleep 3
  else
    log "/new $role/$slug — pane already running $pane_cmd, skip claude start"
  fi
  echo "$role/$slug" > "$(active_chat_file "$tg_chat")"
  start_watcher_for "$pane" "$role/$slug"
  send_tg "✓ created <code>$role/$slug</code> ($pane)
✓ now active chat
🔔 auto-push เปิดอยู่
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
  stop_watcher_for "$target"
  tmux kill-pane -t "$pane" 2>/dev/null
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
  [ -z "$pane" ] && { send_tg "❌ active chat <code>$target</code> ตายแล้ว"; rm -f "$f"; return; }
  local n
  case "$arg" in
    full|all) n=5000 ;;
    *)        n="$arg" ;;
  esac
  local content
  content=$(tmux capture-pane -t "$pane" -pS "-$n" 2>/dev/null)
  send_tg "👁️ <code>$target</code> ($pane, $n lines):
<pre>$(echo "$content" | html_escape)</pre>"
}

cmd_end() {
  local tg_chat="$1"
  rm -f "$(active_chat_file "$tg_chat")"
  send_tg "✓ cleared active chat (watchers ยังเปิดอยู่ — ใช้ /watch off &lt;chat&gt; ถ้าจะเงียบ)"
  update_status "$tg_chat"
}

# /relaunch — re-spawn claude in an existing pane after `claude -p` exited.
# Different from /new: keeps the pane + worktree, just restarts claude inside.
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
  if is_claude "$pane_cmd"; then
    send_tg "✓ claude รันอยู่แล้วใน <code>$target</code> (cmd=<code>$pane_cmd</code>) — ไม่ต้อง relaunch"
    return
  fi
  audit "/relaunch $target pane=$pane prev_cmd=$pane_cmd"
  tmux send-keys -t "$pane" -- "claude --dangerously-skip-permissions" 2>/dev/null
  sleep 0.3
  tmux send-keys -t "$pane" Enter 2>/dev/null
  send_tg "🔄 relaunch claude ใน <code>$target</code> (was <code>${pane_cmd:-?}</code>) — รอสักครู่ให้ขึ้น แล้วลองส่งข้อความใหม่"
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
      local resolved; resolved=$(resolve_chat "$target")
      [ -z "$resolved" ] && { send_tg "❌ ไม่เจอ chat <code>$target</code>"; return; }
      local pane; pane=$(echo "$resolved" | cut -d'|' -f1)
      start_watcher_for "$pane" "$target"
      send_tg "✓ watcher on for <code>$target</code> ($pane)"
      ;;
    off)
      [ -z "$target" ] && {
        local f; f=$(active_chat_file "$CHAT")
        [ -f "$f" ] && target=$(cat "$f")
      }
      [ -z "$target" ] && { send_tg "❌ usage: /watch off &lt;role/slug&gt;"; return; }
      stop_watcher_for "$target"
      send_tg "✓ watcher off for <code>$target</code> (chat ยังอยู่ — push หยุด)"
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
  local role="${target%%/*}" slug="${target#*/}"
  local repo; repo=$(role_repo "$role")
  [ -z "$repo" ] && { send_tg "❌ unknown role: $role"; return; }

  # Resolve the chat's actual worktree cwd from tmux pane (most reliable —
  # supports any worktree layout: maw's <repo>.wt-N-<slug>, claude code's
  # <repo>/.claude/worktrees/<name>, or vanilla <repo> for the oracle pane).
  # Fall back to repo dir if pane is dead.
  local cwd jsonl pane
  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  if [ -n "$pane" ]; then
    cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
  fi
  [ -z "$cwd" ] && cwd="$repo"
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
  [ -z "$jsonl" ] && { send_tg "❌ ไม่เจอ JSONL session ของ <code>$target</code>
cwd ที่ลอง: <code>$cwd</code>
encoded: <code>$(encode_cwd "$cwd")</code>"; return; }
  # Parse last N user/assistant turns. JSONL message.content can be:
  #   - string (simple message)
  #   - array of blocks: text / tool_use / tool_result / thinking
  # Filter to entries with non-empty text; skip pure tool/thinking rows so
  # the output reads like a conversation, not a tool log.
  local turns
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
  [ -z "$turns" ] && { send_tg "❌ JSONL parse ว่าง — schema อาจต่างไป
file: $jsonl"; return; }
  send_tg "📜 <b>history</b> <code>$target</code> (last $n turns):
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
    local age=$(printf '%s' "$(( ($(date +%s) - $(stat -f %m "$latest_jsonl" 2>/dev/null || echo 0)) / 60 ))min")
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
  local role="${target%%/*}"
  local repo; repo=$(role_repo "$role")
  [ -z "$repo" ] && { send_tg "❌ unknown role: $role"; return; }

  local cwd pane jsonl
  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  [ -n "$pane" ] && cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
  [ -z "$cwd" ] && cwd="$repo"
  jsonl=$(find_jsonl "$cwd")
  [ -z "$jsonl" ] && { send_tg "❌ ไม่เจอ JSONL session ของ <code>$target</code>"; return; }

  # Single jq pass so input / output / model come from the same line.
  # Context window load = input_tokens + cache_creation_input_tokens + cache_read_input_tokens.
  # input_tokens alone is just the uncached delta of the latest turn (often 1) — almost
  # all of the prompt lives in cache_read_input_tokens, which is what fills the window.
  local usage_all tokens out_tokens model max_ctx
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

  # Infer context-window tier from the high-water mark across the session.
  # JSONL doesn't expose the [1m] beta — model field is just "claude-opus-4-7" for
  # both 200k and 1M variants. If we ever observed >200k loaded, this must be 1M.
  max_ctx=$(printf '%s' "$usage_all" | awk -F'\t' 'BEGIN{m=0} {if($1+0>m) m=$1+0} END{print m+0}')
  local ctx_max=200000
  [ "$max_ctx" -gt 200000 ] && ctx_max=1000000
  local pct=$((tokens * 100 / ctx_max))
  local remaining=$((ctx_max - tokens))

  local filled=$((pct / 10)) i bar=""
  for i in $(seq 1 10); do
    [ "$i" -le "$filled" ] && bar="${bar}█" || bar="${bar}░"
  done

  local al; al=$(chat_alias "$target")
  [ -n "$al" ] && al=" ($al)"
  local model_line=""
  [ -n "$model" ] && model_line="
model: <code>$model</code>"

  send_tg "📊 <b>${target}${al}</b>
${bar} <b>${pct}%</b>
ctx:    <code>$tokens</code> / <code>$ctx_max</code>${out_tokens:+    output: <code>$out_tokens</code>}
left:   <code>$remaining</code> tokens${model_line}"
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
      local j; j=$(find_jsonl "$cwd")
      [ -z "$j" ] && continue
      local first_ts
      first_ts=$(jq -r 'select(.timestamp) | .timestamp' "$j" 2>/dev/null | head -1)
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
        session_lines+="• <code>${chat}${al}</code>: started ${age_m}m ago (in window)
"
        [ "$epoch" -lt "$oldest_in_window" ] || [ "$oldest_in_window" -eq 0 ] && oldest_in_window=$epoch
      else
        local h=$(( age_m / 60 )) m=$(( age_m % 60 ))
        session_lines+="• <code>${chat}${al}</code>: ${h}h ${m}m old (outside window)
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
  pane=$(resolve_chat "$target" | cut -d'|' -f1)
  [ -z "$pane" ] && { send_tg "❌ active chat <code>$target</code> ตายแล้ว"; rm -f "$f"; return; }
  audit "→ chat=$target pane=$pane text=$text"
  # Refuse if claude isn't running in the pane — text would land in zsh and
  # never reach the agent. Observed 2026-05-01 after pg-tester's `claude -p`
  # exited and the user typed via brewbot, producing zsh "command not found"
  # for every Thai message until they noticed.
  local pane_cmd
  pane_cmd=$(tmux display-message -p -t "$pane" "#{pane_current_command}" 2>/dev/null)
  if ! is_claude "$pane_cmd"; then
    send_tg "❌ claude ไม่ได้รันใน <code>$target</code> (pane cmd=<code>${pane_cmd:-?}</code>) — ข้อความจะตกใน shell, ไม่ส่งให้
รีเริ่ม: <code>/relaunch</code> (active chat) หรือ <code>/relaunch $target</code>"
    return
  fi
  # Mark "user just sent" so the watcher's quiet-window kicks in (avoids
  # auto-pushing back the user's own message + claude's first ack burst).
  date +%s > "$(user_send_marker "$target")"
  # Send text and Enter as SEPARATE send-keys with a small delay between.
  # Reason: claude's TUI input field renders multi-byte Thai chars asynchronously;
  # if Enter is appended in the same send-keys call, it can arrive before the
  # full text has been processed by the TUI's input buffer → message stays in
  # the field unsubmitted (observed 2026-04-28). The 0.3s delay reliably
  # lets the TUI catch up before we press Enter.
  tmux send-keys -t "$pane" -- "$text" 2>/dev/null
  sleep 0.3
  tmux send-keys -t "$pane" Enter 2>/dev/null
  send_tg "→ <code>$target</code> sent. 🔔 watcher จะ push ตอน claude ตอบเสร็จ"
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
    /new)         cmd_new "$chat_id" "${2:-}" "${3:-}" ;;
    /relaunch)    cmd_relaunch "$chat_id" "${2:-}" ;;
    /close)       cmd_close "${2:-}" "${3:-}" ;;
    /look)        cmd_look "$chat_id" "${2:-25}" ;;
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
  while true; do
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
        ack_callback "$cb_id"
        # Translate callback_data → command. Format: "<action>:<arg>"
        case "$cb_data" in
          chat:*)   dispatch "$cb_chat" "/chat ${cb_data#chat:}" ;;
          close:*)  dispatch "$cb_chat" "/close ${cb_data#close:}" ;;
          chats:*)  dispatch "$cb_chat" "/chats ${cb_data#chats:}" ;;
          watch_off:*) dispatch "$cb_chat" "/watch off ${cb_data#watch_off:}" ;;
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

main

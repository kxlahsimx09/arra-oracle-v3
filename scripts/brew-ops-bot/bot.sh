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

REPOS=(
  "$HOME/Code/github.com/kokarat/mobiz-payment-gateway"
  "$HOME/Code/github.com/kokarat/bank-bot"
  "$HOME/Code/github.com/Soul-Brews-Studio/arra-oracle-v3"
)
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
  log "loaded ${#ROLES[@]} roles: $(echo "${ROLES[@]}" | tr ' ' '\n' | cut -d'|' -f1 | tr '\n' ' ')"
}
load_roles

# ── helpers ────────────────────────────────────────────────────────────────

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
audit() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$AUDIT_FILE"; }

# HTML-escape dynamic content before embedding in send_tg's parse_mode=HTML.
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
  if [ -z "$resp" ] || ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
    log "send_tg failed: $(echo "$resp" | head -c 300)"
  fi
}

active_chat_file() { echo "${ACTIVE_CHAT_FILE_PREFIX}.$1"; }

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

# Resolve <role>/<slug> or just <role> to a pane line. Returns "" if ambiguous or not found.
resolve_chat() {
  local target="$1"
  if [[ "$target" == *"/"* ]]; then
    local role="${target%%/*}" slug="${target#*/}"
    chats_for_role "$role" | awk -F'|' -v s="$slug" '$5==s {print; exit}'
  else
    # bare <role>: only OK if exactly one chat exists
    local lines
    lines=$(chats_for_role "$target")
    [ "$(echo "$lines" | grep -c .)" = "1" ] && echo "$lines"
  fi
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
/chat &lt;role[/slug]&gt;       switch context (auto-pick if 1 chat)
/new &lt;role&gt; [slug]        spawn new chat (uses maw wake)
/close &lt;role/slug&gt;        kill chat (pane + leaves worktree orphan)

<b>Active chat I/O:</b>
&lt;plain msg&gt;               → send to current chat
/look [N|full]            tmux scrollback (default 25)
/end                      clear active chat (no kill)
/watch list|on|off|all    🔔 manage per-chat auto-push

<b>History:</b>
/history [target] [N]     claude JSONL (last N turns; default 20)
/retro [role] [N]         workflow retros (default 5)
/closed                   recently-ended chats with JSONL still on disk

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
  [ -z "$target" ] && { send_tg "❌ usage: /chat &lt;role&gt; หรือ /chat &lt;role/slug&gt;"; return; }
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
  send_tg "✓ active chat: <code>$role/$slug</code> ($pane, cmd=$cmd)
ส่งข้อความตอนนี้ → ไป chat นี้
/watch ดู watcher status, /look /history ดูเนื้อหา"
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
  # start interactive claude
  tmux send-keys -t "$pane" "claude --dangerously-skip-permissions" Enter 2>/dev/null
  sleep 3
  echo "$role/$slug" > "$(active_chat_file "$tg_chat")"
  start_watcher_for "$pane" "$role/$slug"
  send_tg "✓ created <code>$role/$slug</code> ($pane)
✓ now active chat
🔔 auto-push เปิดอยู่
ส่งข้อความเริ่มคุย หรือ /look ดู splash"
}

# Delegate chat audit + cleanup to a brew-ops claude session.
# Generates a structured task prompt with the current chat list + per-chat
# state (dirty / unpushed / claude-busy) and asks brew-ops to:
#   - decide what to do per chat (close / commit-and-close / leave-alive)
#   - actually execute (tmux kill-pane, git ops)
#   - report back (output flows via chat-watcher → Telegram)
delegate_close_to_brew_ops() {
  local slug="audit-$(date +%H%M%S)"
  local chat_id="brew-ops/$slug"
  local repo; repo=$(role_repo "brew-ops")
  if [ -z "$repo" ]; then send_tg "❌ no brew-ops role configured"; return; fi

  # Build audit dump of every non-oracle chat
  local audit_lines=""
  while IFS= read -r role; do
    [ -z "$role" ] && continue
    while IFS='|' read -r pane sess win cmd s; do
      [ -z "$pane" ] && continue
      [ "$s" = "oracle" ] && continue
      local cwd; cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
      local dirty=0 ahead=0 busy="no"
      if [ -n "$cwd" ] && [ -e "$cwd/.git" ]; then
        dirty=$(git -C "$cwd" status --short 2>/dev/null | wc -l | tr -d ' ')
        ahead=$(git -C "$cwd" log origin/main..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
      fi
      # Busy heuristic: present-progressive forms only ("Brewing", not "Brewed").
      # "esc to interrupt" = claude actively running tool/streaming. Past-tense
      # forms like "Baked for 2m 23s" mean DONE — we used to false-positive on those.
      if tmux capture-pane -t "$pane" -pS -8 2>/dev/null | grep -qE "esc to interrupt|⏸|(Brew|Saut[eé]|Bak|Cogitat|Churn|Whisk|Steam|Knead|Toss|Simmer|Roast|Sizzl|Stew|Marinad|Glaz|Carameliz|Reduc|Blend|Fold|Drizzl)ing"; then
        busy="yes"
      fi
      audit_lines+="- chat=$role/$s pane=$pane cmd=$cmd cwd=$cwd dirty=$dirty ahead=$ahead busy=$busy
"
    done <<< "$(chats_for_role "$role")"
  done <<< "$(all_roles)"

  if [ -z "$audit_lines" ]; then
    send_tg "ไม่มี non-oracle chats ให้ปิด"
    return
  fi

  # Write task prompt
  local promptfile="$STATE_DIR/wake-prompts/brew-ops-$slug.md"
  mkdir -p "$STATE_DIR/wake-prompts"
  cat > "$promptfile" <<EOF
You are brew-ops. The user has too many chats to review individually and wants you to handle cleanup. Decide what to close, wrap up, or leave alive — and report back. **Avoid losing work at all costs.**

## Chats to audit (auto-collected)

$audit_lines

## Goal

Close chats that are demonstrably safe, wrap up chats whose work can be finished cleanly, and leave alive anything ambiguous or in-progress.

## Per-chat steps

1. **Inspect context before deciding:**
   - \`tmux capture-pane -t <pane> -pS -100\` — see what claude was doing
   - \`git -C <cwd> status --short\` — what's dirty
   - \`git -C <cwd> log origin/main..HEAD\` — commits ahead of main
   - \`git -C <cwd> branch --show-current\` — current branch
   - \`git -C <cwd> rev-parse --abbrev-ref @{u} 2>/dev/null\` — does it have an upstream?

2. **GOLDEN RULE: NO DATA LOSS** ⚠️

   **Do NOT kill a pane** until you've verified:
   - (a) every commit exists on a remote (origin or fork) — \`git rev-list <branch> --not --remotes\` must return 0 lines
   - (b) the worktree has no dirty / untracked files — \`git status --short\` must be empty (after any wrap-up commit/push)
   - (c) **no SESSION-STRAY \`ψ/\` content in the worktree** — see exception list below. Stray ψ/ memory inside a worktree where it doesn't belong indicates an arra-oracle tools bug; if found, leave alive for human review.

     **Exception list — repos where \`ψ/\` is legitimate, SKIP the check:**
     - \`mb_agent_oracle_memory\` — canonical home of memory (ψ/ lives here by design)
     - \`kokarat/mobiz-payment-gateway\` — legacy ψ/ from the project's developer, predates our oracle ecosystem
     - \`kokarat/bank-bot\` — same legacy from project developer
     For these repos: pretend ψ/ doesn't exist for guard (c) — don't check, don't block.

     **For all other repos (arra-oracle-v3, maw-js, oracle-studio, mb-next-payment-gateway, etc.):**
     Check: \`find <cwd> -type d -name "ψ" 2>/dev/null\` — must be empty.
     ALSO check whether THIS session created any ψ/ content (catches the bug even in repos where ψ/ legitimately exists already): \`git -C <cwd> diff origin/main..HEAD --name-only -- "ψ/" | wc -l\` plus untracked: \`git -C <cwd> ls-files --others --exclude-standard -- "ψ/" | wc -l\` — sum must be 0. If session_added > 0 → stray (block).

   - If ANY of (a)/(b)/(c) fails → **MUST leave alive** (no exceptions)

   **Vault repo (\`mb_agent_oracle_memory\`) dirty is NOT a blocker** — that's the canonical home for memory. If you find uncommitted changes there during wrap-up, just commit + push to its current branch (likely \`main\`) and move on. Don't block on it.

3. **For unsafe chats: infer the WIP intent before deciding**

   If you're going to leave a chat alive, you need to understand what it was trying to do, so you can tell the user what's stuck and why "don't delete this one" is the right call. Sources:
   - **JSONL session log:** \`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl\` — read recent assistant + user turns to summarize the in-progress task
   - **Pane scrollback:** \`tmux capture-pane -pS -200\` — recent context
   - **Dirty file diff:** \`git -C <cwd> diff\` + \`git diff --cached\` — what content is being edited
   - **Untracked files:** \`git status --short\` shows new files; cat them if small
   - **Memory / retros:** if cwd is under \`mb_agent_oracle_memory\`, check ψ/memory/learnings + ψ/memory/retrospectives for files this session created
   - **arra_thread:** if a thread was opened from this session, note its id

   Summarize in 1–2 sentences: "was attempting <X>, blocked at <Y>" — used in the "Kept alive" report section.

4. **Categorize:**

   **A. SAFE close** — passes all 3 guards
   - dirty=0, ahead=0 (or all commits on remote), claude exited (cmd=zsh)
   - no stray ψ/ in worktree
   - → \`tmux kill-pane -t <pane>\` + \`git -C <repo-root> worktree prune\`

   **B. WRAP-UP then close** — has pending work that can finish cleanly
   - dirty>0 and the changes look like a complete unit → \`git -C <cwd> add -A && git -C <cwd> commit -m "<descriptive message>" && git -C <cwd> push -u fork <branch>\`
   - ahead>0 not pushed → \`git -C <cwd> push -u fork <branch>\` (or origin if you have push access)
   - **vault repo dirty (mb_agent_oracle_memory)**: not a blocker — just \`git -C <vault> add -A && git -C <vault> commit -m "memory: session <chat> wrap" && git -C <vault> push\` on its current branch (typically \`main\`). Memory is supposed to live there.
   - **After wrap-up: re-verify guards (a)+(b)+(c)** — if push failed / network glitch / stray ψ/ remains → leave alive

   **C. LEAVE ALIVE** — do not close
   - busy=yes (claude is brewing/cogitating/thinking) — typing into it is harmful
   - dirty>0 but the files look like a work-in-progress that needs human review (you can't write a confident commit message)
   - claude is waiting for a Y/N or other confirm — leave it for the user to answer
   - branch has no upstream and no fork remote configured — can't push → leave alive
   - any of guard (a)/(b)/(c) fails after a wrap-up attempt → **leave alive immediately** and report

5. **Report via Telegram** using \`mcp__tester-telegram__telegram_send\` (chat 2002026175, bot \`@ampay_test_alert_bot\`). Format:

\`\`\`
🧹 brew-ops cleanup report

✅ Closed (N) — verified safe:
  - <chat>: clean, no ahead, claude exited
  ...

📤 Wrapped + closed (M) — committed/pushed/verified:
  - <chat>: committed "<msg>" + pushed → fork/<branch> (sha=<short>)
  ...

⏸ Kept alive (K) — reason + WIP context:
  - <chat>: claude busy (Brewing 3m)
    └ Doing: <summarize from JSONL/scrollback what task is in progress>
  - <chat>: dirty WIP files need human review (<files preview>)
    └ Intent: <summarize from JSONL turns + dirty diff what is being attempted>
    └ Last action: <claude last assistant turn snippet>
  - <chat>: branch has no upstream + push failed
    └ Intent: <inferred from history>
  ...

🔍 Verification on every closed chat:
  - guard (a) all commits on remote: ✅
  - guard (b) worktree clean (no dirty/untracked): ✅
  - guard (c) no session-stray ψ/ added (legacy ψ/ in mobiz/bank-bot/vault is OK): ✅
\`\`\`

## Constraints

- **Do NOT touch -oracle baselines** (keep them — user uses them)
- **Do NOT close your own pane** (chat \`$chat_id\`) — the user will /close it themselves after reading your report
- **Never \`push --force\`** (regular push only)
- **Never \`rm -rf\` / \`git reset --hard\` / \`git stash drop\`** (preserve all data)
- **Default to safe: when in doubt → leave alive** (no harm done)
- Closing requires every commit and every dirty file to be on a remote (origin or fork) — otherwise keep
- Branch with no upstream and no working push target → **leave alive**, never close
- Vault repo dirty (\`mb_agent_oracle_memory\`) is fine — just commit + push to its main during wrap-up; never a blocker
- Stray \`ψ/\` ADDED BY THIS SESSION is a blocker (tools-bug signal). But pre-existing ψ/ in the exception-list repos (\`mb_agent_oracle_memory\`, \`kokarat/mobiz-payment-gateway\`, \`kokarat/bank-bot\`) is fine and must be ignored — that's legacy / canonical-home content unrelated to our workflow.

## Expected end state

- ✅ All -oracle baselines still alive (untouched)
- ✅ Your own chat (\`$chat_id\`) still alive (so user can read the report)
- ❌ Non-oracle, non-self chats: each handled per the decision (closed / wrapped+closed / left-alive)

## Notes

- Chat worktrees live under \`.claude/worktrees/\` or \`<repo>.wt-N-<slug>\`
- Some chats may already be on a feature branch (e.g. docs/track-*) — figure out from git branch
- After killing a pane, run \`git -C <repo-root> worktree prune\` to clean orphans
EOF

  send_tg "🤖 spawning <code>$chat_id</code> ให้ brew-ops จัดการ chat cleanup
รายงานจะ push กลับมาเมื่อ brew-ops ตอบ"

  # Pre-flight: pull main (skip dirty-check noise; brew-ops worktree forks from main)
  git -C "$repo" fetch origin main 2>/dev/null
  local cur_b; cur_b=$(git -C "$repo" branch --show-current 2>/dev/null)
  if [ "$cur_b" = "main" ]; then
    git -C "$repo" merge --ff-only origin/main 2>/dev/null
  else
    git -C "$repo" update-ref refs/heads/main origin/main 2>/dev/null
  fi

  # Spawn worktree + pane via maw
  maw wake brew-ops --wt "$slug" --fresh >/dev/null 2>&1
  sleep 3

  # Find the new pane
  local pane; pane=$(tmux list-panes -a -F "#{pane_id}|#{window_name}" 2>/dev/null \
    | awk -F'|' -v w="brew-ops-$slug" '$2==w{print $1; exit}')
  if [ -z "$pane" ]; then
    send_tg "❌ pane brew-ops-$slug ไม่ถูกสร้าง"
    return
  fi

  # Start claude if at shell (race-safe with maw template)
  local pcmd; pcmd=$(tmux list-panes -t "$pane" -F "#{pane_current_command}" 2>/dev/null | head -1)
  if echo "$pcmd" | grep -qE '^(zsh|bash|sh|fish)$'; then
    tmux send-keys -t "$pane" -- "claude --dangerously-skip-permissions" 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$pane" Enter 2>/dev/null
    sleep 3
  fi

  # Send the task pointer (claude reads file)
  local task_msg="Read $promptfile in full — that is your task, every line. Follow all instructions in the file, do not skip any."
  date +%s > "$(user_send_marker "$chat_id")"
  tmux send-keys -t "$pane" -- "$task_msg" 2>/dev/null
  sleep 0.3
  tmux send-keys -t "$pane" Enter 2>/dev/null

  # Set as active + start watcher
  echo "$chat_id" > "$(active_chat_file "$CHAT")"
  start_watcher_for "$pane" "$chat_id"
}

cmd_close() {
  local target="$1" mode="${2:-}"
  [ -z "$target" ] && { send_tg "❌ usage:
  /close &lt;role/slug&gt;        — single chat
  /close all                  — audit + ลบเฉพาะ safe (ไม่แตะ -oracle)
  /close all force            — skip audit, kill ทุก non-oracle
  /close all auto             — 🤖 delegate ให้ brew-ops agent จัดการ
  /close everything           — audit + ลบ safe (รวม -oracle)
  /close everything force     — kill ทุกอย่างเลย"; return; }

  # /close all auto — spawn brew-ops chat to do audit + cleanup intelligently
  if [ "$target" = "all" ] && [ "$mode" = "auto" ]; then
    audit "/close all auto"
    delegate_close_to_brew_ops
    return
  fi

  # /close all (skip oracle) | /close everything (include oracle)
  if [ "$target" = "all" ] || [ "$target" = "everything" ]; then
    local include_oracle=false
    [ "$target" = "everything" ] && include_oracle=true
    local force=false
    [ "$mode" = "force" ] && force=true
    audit "/close $target $mode"

    # Collect (chat, pane, cwd) tuples to consider
    local candidates=""
    while IFS= read -r role; do
      [ -z "$role" ] && continue
      while IFS='|' read -r pane sess win cmd slug; do
        [ -z "$pane" ] && continue
        if [ "$slug" = "oracle" ] && [ "$include_oracle" = "false" ]; then continue; fi
        candidates+="$role/$slug|$pane|$cmd"$'\n'
      done <<< "$(chats_for_role "$role")"
    done <<< "$(all_roles)"

    [ -z "$candidates" ] && { send_tg "ไม่มี chat ที่จะปิด"; return; }

    if [ "$force" = "true" ]; then
      # No audit — kill everything in candidates
      local count=0
      while IFS='|' read -r chat pane cmd; do
        [ -z "$chat" ] && continue
        stop_watcher_for "$chat"
        tmux kill-pane -t "$pane" 2>/dev/null
        count=$((count + 1))
      done <<< "$candidates"
      [ "$include_oracle" = "true" ] && rm -f "$STATE_DIR"/active-chat.* "$STATE_DIR"/last-line.* 2>/dev/null
      send_tg "✓ force-closed $count chat(s)
worktrees ที่ orphan: <code>git worktree prune</code> เอง"
      return
    fi

    # Audit each candidate
    local safe_list="" unsafe_report=""
    local safe_n=0 unsafe_n=0
    while IFS='|' read -r chat pane cmd; do
      [ -z "$chat" ] && continue
      local cwd; cwd=$(tmux display-message -p -t "$pane" "#{pane_current_path}" 2>/dev/null)
      local issues=""
      # 1. dirty worktree
      if [ -n "$cwd" ] && [ -d "$cwd/.git" -o -f "$cwd/.git" ]; then
        local dirty; dirty=$(git -C "$cwd" status --short 2>/dev/null | wc -l | tr -d ' ')
        [ "$dirty" -gt 0 ] && issues+="
   • $dirty dirty file(s)"
        # 2. unpushed commits vs origin/main
        local unpushed; unpushed=$(git -C "$cwd" log origin/main..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
        [ "$unpushed" -gt 0 ] && issues+="
   • $unpushed commit(s) ahead of origin/main"
      fi
      # 3. claude busy heuristic — pane content shows spinner / interrupt hint
      local pcontent; pcontent=$(tmux capture-pane -t "$pane" -pS -8 2>/dev/null | tail -8)
      if echo "$pcontent" | grep -qE "esc to interrupt|✻|✶|✢|⏸|Brewing|Cogitating|Thinking"; then
        issues+="
   • claude อาจ busy หรือรอ confirm (ดู /look)"
      fi

      if [ -z "$issues" ]; then
        safe_list+="$chat|$pane"$'\n'
        safe_n=$((safe_n + 1))
      else
        unsafe_report+="
⚠️ <code>$chat</code>:$issues"
        unsafe_n=$((unsafe_n + 1))
      fi
    done <<< "$candidates"

    # Close the safe ones
    while IFS='|' read -r chat pane; do
      [ -z "$chat" ] && continue
      stop_watcher_for "$chat"
      tmux kill-pane -t "$pane" 2>/dev/null
    done <<< "$safe_list"

    local note="🔍 <b>Audit + close $target</b>
✅ closed $safe_n safe chat(s)"
    if [ "$unsafe_n" -gt 0 ]; then
      note+="

🛑 <b>$unsafe_n unsafe (kept alive):</b>$unsafe_report

ใช้ <code>/close $target force</code> เพื่อ kill ทั้งหมด (รวม unsafe)
หรือจัดการรายตัวก่อน:
  /look /chat &lt;chat&gt; → ดู/wrap up
  cd worktree → commit/push/stash"
    fi
    send_tg "$note"
    return
  fi

  local resolved
  resolved=$(resolve_chat "$target")
  [ -z "$resolved" ] && { send_tg "❌ ไม่เจอ chat <code>$target</code>"; return; }
  local pane
  pane=$(echo "$resolved" | cut -d'|' -f1)
  audit "/close $target ($pane)"
  stop_watcher_for "$target"
  tmux kill-pane -t "$pane" 2>/dev/null
  # clear active state if it was the target
  local f; f=$(active_chat_file "$CHAT")
  [ -s "$f" ] && [ "$(cat "$f")" = "$target" ] && rm -f "$f"
  send_tg "✓ closed <code>$target</code> ($pane)
หมายเหตุ: worktree ของ chat นี้ยัง orphan — รัน <code>git worktree prune</code> ใน repo นั้น"
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
    /new)         cmd_new "$chat_id" "${2:-}" "${3:-}" ;;
    /close)       cmd_close "${2:-}" "${3:-}" ;;
    /look)        cmd_look "$chat_id" "${2:-25}" ;;
    /end)         cmd_end "$chat_id" ;;
    /watch)       cmd_watch "${2:-list}" "${3:-}" ;;
    /history)     cmd_history "$chat_id" "${2:-}" "${3:-20}" ;;
    /retro)       cmd_retro "${2:-}" "${3:-}" ;;
    /closed)      cmd_closed ;;
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
  local last_id=0
  [ -f "$LAST_UPDATE_ID_FILE" ] && last_id=$(cat "$LAST_UPDATE_ID_FILE")
  while true; do
    local resp
    resp=$(curl -sf --max-time 35 "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=$((last_id + 1))&timeout=30" 2>/dev/null) || { sleep 5; continue; }
    local n; n=$(echo "$resp" | jq '.result | length' 2>/dev/null)
    [ "${n:-0}" -eq 0 ] && continue
    for i in $(seq 0 $((n - 1))); do
      local update_id chat_id text
      update_id=$(echo "$resp" | jq ".result[$i].update_id")
      chat_id=$(echo "$resp" | jq ".result[$i].message.chat.id // empty")
      text=$(echo "$resp" | jq -r ".result[$i].message.text // empty")
      last_id=$update_id
      echo "$last_id" > "$LAST_UPDATE_ID_FILE"
      [ -z "$chat_id" ] || [ -z "$text" ] && continue
      dispatch "$chat_id" "$text"
    done
  done
}

main

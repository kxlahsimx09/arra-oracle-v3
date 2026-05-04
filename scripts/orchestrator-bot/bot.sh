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
    local cur=$(curl -sf "$ORACLE_API/thread/$id" 2>/dev/null | jq -r '.thread.status // empty' 2>/dev/null)
    [ -z "$cur" ] && cur="$old_status"
    printf '%s|%s|%s|%s\n' "$id" "$title" "$cur" "$opened" >> "$tmp"
  done < "$KNOWN_THREADS_FILE"
  mv "$tmp" "$KNOWN_THREADS_FILE"
}

# Smart-default: when no active thread is set, find a single pending parent
# thread the user is plausibly responding to. Heuristic: thread is pending,
# is a parent (title doesn't start with "[from "), and its most recent
# message is from `claude` within the last SMART_THREAD_WINDOW_SEC. When
# exactly one such thread exists, return its id so plain text attaches as
# a continuation. Returns empty when 0 or >1 candidates (caller falls back
# to a fresh request — no auto-attach when ambiguous).
#
# Uses the live oracle API (not known-threads cache) because threads opened
# by the orchestrator agent itself never enter the cache — the cache only
# tracks threads the user touches via /use or /threads commands. Cost is
# 1 list call + N detail calls per dispatch (N = pending-parent count).
SMART_THREAD_WINDOW_SEC=${SMART_THREAD_WINDOW_SEC:-1800}
pick_smart_active_thread() {
  local resp
  resp=$(curl -sf -m 5 "$ORACLE_API/threads?limit=30" 2>/dev/null) || return
  echo "$resp" | jq -e '.threads' >/dev/null 2>&1 || return
  local now=$(date +%s)
  local cutoff=$((now - SMART_THREAD_WINDOW_SEC))
  local pending_parents
  pending_parents=$(echo "$resp" | jq -r '
    .threads[]
    | select(.status == "pending")
    | select(.title | startswith("[from ") | not)
    | .id')
  local candidates=()
  local tid thread_full last_role last_ts ts_clean last_epoch
  for tid in $pending_parents; do
    thread_full=$(curl -sf -m 5 "$ORACLE_API/thread/$tid" 2>/dev/null) || continue
    last_role=$(echo "$thread_full" | jq -r '.messages[-1].role // empty' 2>/dev/null)
    # REST API uses created_at; MCP shape uses timestamp. Try both.
    last_ts=$(echo "$thread_full" | jq -r '.messages[-1] | (.created_at // .timestamp // empty)' 2>/dev/null)
    [ "$last_role" = "claude" ] || continue
    [ -n "$last_ts" ] || continue
    # API timestamps are UTC (e.g. 2026-05-04T05:44:08.517Z). BSD `date -j -f`
    # without -u parses as local time, misreading UTC inputs by tz offset.
    # Strip fractional seconds + trailing Z, parse with -u for UTC.
    ts_clean="${last_ts%%.*}"
    ts_clean="${ts_clean%Z}"
    last_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ts_clean" "+%s" 2>/dev/null) || continue
    [ "$last_epoch" -ge "$cutoff" ] || continue
    candidates+=("$tid")
  done
  [ "${#candidates[@]}" -eq 1 ] && echo "${candidates[0]}"
}

# Write a request envelope (plain-text dispatch from user).
# When `thread` is set (active-thread sticky after /use N), the user's message
# is ON that thread (not a parent of it) — write `thread: N` so the inbox-
# watcher can match thread-N session-id mapping for Path 1 worktree-reuse.
write_envelope() {
  local text="$1" thread="$2"
  local ts=$(date '+%Y-%m-%d_%H-%M')
  local fname="${ts}_from-user_request"
  [ -n "$thread" ] && fname="${ts}_from-user_thread-${thread}_continuation"
  fname="${fname}.md"
  local path="$INBOX_DIR/$fname"

  {
    echo "---"
    echo "from: user"
    echo "from_role: human"
    echo "to: orchestrator"
    echo "to_role: orchestrator"
    echo "type: consult"
    [ -n "$thread" ] && echo "thread: $thread"
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
  log "wrote envelope: $fname (thread=${thread:-none})"
  echo "$path"
}

# ── command handlers ───────────────────────────────────────────────────────

cmd_help() {
  send_tg "$(cat <<EOF
<b>Orchestrator commands</b>

<code>/threads</code> — list open + closed threads (parent → sub hierarchy)
<code>/use N</code>  — switch active thread to #N
<code>/new</code>    — clear active, next message starts fresh request
<code>/peek N</code> — preview last 3 messages of #N (no switch)
<code>/read N</code> — publish full thread #N to Telegraph + send link
<code>/close N</code> — mark #N closed
<code>/cancel N</code> — request orchestrator to cancel #N
<code>/status</code> — active + pending sub-threads + watcher alerts
<code>/escalations</code> — unresolved escalations across fleet
<code>/cleanup</code> — one-tap fleet cleanup audit (orchestrator → brew-ops)

Plain text → continues active thread, or starts fresh.
EOF
)"
}

# Telegraph helper — get-or-create an access token, cached in env file.
ensure_telegraph_token() {
  if [ -n "${TELEGRAPH_TOKEN:-}" ]; then
    echo "$TELEGRAPH_TOKEN"
    return 0
  fi
  local resp
  resp=$(curl -sf "https://api.telegra.ph/createAccount?short_name=orchestrator&author_name=orchestrator-bot&author_url=" 2>&1)
  local token
  token=$(echo "$resp" | jq -r '.result.access_token // empty' 2>/dev/null)
  if [ -z "$token" ]; then
    log "telegraph createAccount failed: $(echo "$resp" | head -c 200)"
    return 1
  fi
  # Persist for next invocation
  printf '\nTELEGRAPH_TOKEN=%s\n' "$token" >> "$ENV_FILE"
  TELEGRAPH_TOKEN=$token
  echo "$token"
}

# Publish $2 (markdown body) under $1 (title) to Telegraph; echo the URL.
# Returns 1 on failure (caller should send_tg an error). Markdown is converted
# to a flat list of paragraphs / headings / code blocks — Telegraph's DOM is
# simpler than markdown so we lose nuance (no nested lists, no inline links
# from raw URLs etc), but the result is readable for thread content review.
publish_telegraph() {
  local title="$1" body_md="$2"
  local token
  token=$(ensure_telegraph_token) || return 1
  # Convert markdown body to Telegraph node array via jq.
  # Strategy: split on blank lines (paragraph boundaries), then per chunk:
  #   - starts with `# ` / `## ` / `### ` → h3 (Telegraph only supports h3/h4)
  #   - starts with ```` ``` ```` → pre
  #   - else → p
  local nodes
  nodes=$(printf '%s' "$body_md" | jq -Rs '
    split("\n\n")
    | map(
        if startswith("```") then
          { tag: "pre", children: [ ltrimstr("```") | rtrimstr("```") | ltrimstr("\n") | rtrimstr("\n") ] }
        elif startswith("### ") then
          { tag: "h4", children: [ ltrimstr("### ") ] }
        elif startswith("## ") then
          { tag: "h3", children: [ ltrimstr("## ") ] }
        elif startswith("# ") then
          { tag: "h3", children: [ ltrimstr("# ") ] }
        elif . == "" or . == "\n" then empty
        else
          { tag: "p", children: [ . ] }
        end
      )
  ')
  local resp
  resp=$(curl -sf -X POST "https://api.telegra.ph/createPage" \
    --data-urlencode "access_token=$token" \
    --data-urlencode "title=$(echo "$title" | head -c 200)" \
    --data-urlencode "author_name=orchestrator" \
    --data-urlencode "content=$nodes" 2>&1)
  local url
  url=$(echo "$resp" | jq -r '.result.url // empty' 2>/dev/null)
  if [ -z "$url" ]; then
    log "telegraph createPage failed: $(echo "$resp" | head -c 300)"
    return 1
  fi
  echo "$url"
}

cmd_read() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    send_tg "❌ <code>/read &lt;N&gt;</code> needs a thread id"
    return
  fi
  local resp
  resp=$(curl -sf "$ORACLE_API/thread/$n" 2>/dev/null)
  if ! echo "$resp" | jq -e '.thread' >/dev/null 2>&1; then
    send_tg "❌ thread #$n not found"
    return
  fi
  local title status count
  title=$(echo "$resp" | jq -r '.thread.title // empty')
  status=$(echo "$resp" | jq -r '.thread.status // empty')
  count=$(echo "$resp" | jq -r '.thread.message_count // 0')
  # Build markdown body — header + each message as h2 + content. Cap each
  # message at TELEGRAPH_MAX_MSG_CHARS (default 6000) to stay under Telegraph's
  # ~64KB createPage limit. A 12-msg thread × 6KB = 72KB headroom — generous.
  # Oversized messages get a "[…truncated]" tail pointing to oracle UI.
  local max_chars=${TELEGRAPH_MAX_MSG_CHARS:-6000}
  local body
  body=$(echo "$resp" | jq -r --argjson cap "$max_chars" --arg tid "$n" '
    .messages[]
    | (.content
        | if length > $cap
          then .[0:($cap - 120)] + "\n\n[…truncated at \($cap) chars — open oracle UI at http://localhost:47778/thread/\($tid) for the full message]"
          else .
          end
      ) as $c
    | "## msg #\(.id) — \(.author) — \(.timestamp)\n\n\($c)\n\n---"
  ')
  local header
  header="# Thread #$n: $title

Status: **$status** · Messages: $count

---

"
  local url
  url=$(publish_telegraph "Thread #$n: $title" "$header$body") || {
    send_tg "❌ telegraph publish failed (check $LOG_FILE for details)"
    return
  }
  send_tg "📖 <b>Thread #$n</b> — $(echo "$title" | head -c 80 | html_escape)
status: $status · $count message(s)
🔗 $url"
}

cmd_threads() {
  local active=$(get_active_thread)
  # Query API directly so sub-threads (opened by orchestrator session, not
  # via this bot) and closed threads both surface. The local known-threads
  # cache is a fallback that only sees parents from this chat.
  local resp
  resp=$(curl -sf "$ORACLE_API/threads?limit=30" 2>/dev/null)
  if ! echo "$resp" | jq -e '.threads' >/dev/null 2>&1; then
    send_tg "<i>Oracle API unreachable at $ORACLE_API. Try <code>/status</code>.</i>"
    return
  fi
  # Build sub→parent map from title convention. Orchestrator has used two
  # variants for tagging sub threads, both supported here:
  #   "...(sub of #66)"       — original convention (#67, #68 era)
  #   "...[for parent #69]"   — newer convention (#70, #71 era)
  # Title-only because body-scan creates false positives: a sub's body often
  # references its *parent* (e.g. "sibling to #66" or "parent #69"), and the
  # body-scan regex can't distinguish parent-references from child-references,
  # which previously rendered the parent as a "sub" of its own child.
  # Map shape: each line is "sub_id|parent_id".
  local sub_parent_map
  sub_parent_map=$(echo "$resp" | jq -r '
    def parent_id:
      (try (capture("\\(sub of #(?<p>[0-9]+)\\)") | .p) catch null)
      // (try (capture("\\[for parent #(?<p>[0-9]+)\\]") | .p) catch null);
    .threads[]
    | . as $t
    | ($t.title | parent_id) as $parent
    | select($parent != null)
    | "\($t.id)|\($parent)"
  ' 2>/dev/null)
  # Resolve "is this id a sub" — used to skip subs in the top-level iteration.
  is_sub() {
    local id="$1"
    echo "$sub_parent_map" | awk -F'|' -v id="$id" '$1 == id { print; exit }' | grep -q .
  }
  # Resolve subs of a parent — used to list children under each parent header.
  subs_of() {
    local pid="$1"
    echo "$sub_parent_map" | awk -F'|' -v pid="$pid" '$2 == pid { print $1 }'
  }

  # Two-pass display: parents first (titles not starting with "[from " AND
  # not themselves a sub), subs indented under their parent. Cap total output
  # at 14 entries (Telegram message limits).
  local body=""
  local count=0
  while IFS='|' read -r id status title; do
    [ -z "$id" ] && continue
    [ "$count" -ge 14 ] && break
    is_sub "$id" && continue   # subs render under their parent below
    local marker
    case "$status" in
      closed)         marker="[×]" ;;
      pending|active) marker="[ ]" ;;
      answered)       marker="[~]" ;;
      *)              marker="[?]" ;;
    esac
    [ "$id" = "$active" ] && marker="[✓]"
    local title_short
    title_short=$(echo "$title" | head -c 50 | html_escape)
    body="${body}${marker} #${id}  ${title_short}"$'\n'
    count=$((count + 1))
    # Subs from the title-derived map. Body-scan fallback removed in 2026-05-04
    # fix: it produced false positives where a sub's body referenced its parent
    # (the regex couldn't tell which direction the relationship went, and
    # would render the parent as a sub of its own child).
    local sub_ids
    sub_ids=$(subs_of "$id")
    for sid in $sub_ids; do
      [ "$sid" = "$id" ] && continue
      [ "$count" -ge 14 ] && break
      local sub_status sub_title
      sub_status=$(echo "$resp" | jq -r ".threads[] | select(.id == $sid) | .status // empty")
      sub_title=$(echo "$resp" | jq -r ".threads[] | select(.id == $sid) | .title // empty" | head -c 50 | html_escape)
      [ -z "$sub_status" ] && continue
      local sub_marker
      case "$sub_status" in
        closed)         sub_marker="[×]" ;;
        pending|active) sub_marker="[ ]" ;;
        answered)       sub_marker="[~]" ;;
        *)              sub_marker="[?]" ;;
      esac
      [ "$sid" = "$active" ] && sub_marker="[✓]"
      body="${body}    └─ ${sub_marker} #${sid}  ${sub_title}"$'\n'
      count=$((count + 1))
    done
  done < <(echo "$resp" | jq -r '
    .threads[]
    | select(.title | startswith("[from ") | not)
    | "\(.id)|\(.status)|\(.title)"
  ')
  if [ -z "$body" ]; then
    send_tg "<i>No threads found.</i>"
    return
  fi
  send_tg "<b>Threads (recent):</b>
<pre>$body</pre>
[✓]=active  [ ]=open  [×]=closed  [~]=answered
<code>/use N</code> switch · <code>/peek N</code> preview · <code>/read N</code> full · <code>/cancel N</code> close"
}

cmd_use() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then send_tg "❌ <code>/use &lt;N&gt;</code> needs a thread id"; return; fi
  # Verify via API — local cache misses sub threads, want to allow /use any.
  local resp title status
  resp=$(curl -sf "$ORACLE_API/thread/$n" 2>/dev/null)
  title=$(echo "$resp" | jq -r '.thread.title // empty' 2>/dev/null)
  status=$(echo "$resp" | jq -r '.thread.status // empty' 2>/dev/null)
  if [ -z "$title" ]; then
    send_tg "❌ thread #$n not found via API. <code>/threads</code> to list."
    return
  fi
  set_active_thread "$n"
  local extra=""
  [ "$status" = "closed" ] && extra=" — <i>note: thread is closed; messages may be ignored</i>"
  send_tg "✓ active → #$n ($(echo "$title" | head -c 60 | html_escape))$extra"
}

cmd_new() {
  clear_active_thread
  send_tg "✓ active cleared. Next message starts a fresh request."
}

cmd_peek() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then send_tg "❌ <code>/peek &lt;N&gt;</code> needs a thread id"; return; fi
  local resp=$(curl -sf "$ORACLE_API/thread/$n" 2>/dev/null)
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
    /read\ *)                 cmd_read "${text#/read }" ;;
    /*)                       send_tg "❓ unknown command. /help" ;;
    *)
      local active=$(get_active_thread)
      local smart=""
      if [ -z "$active" ]; then
        smart=$(pick_smart_active_thread)
      fi
      local target="${active:-$smart}"
      local path=$(write_envelope "$text" "$target")
      if [ -n "$active" ]; then
        send_tg "📨 continuation → thread #$active (orchestrator wakes within 60s)"
      elif [ -n "$smart" ]; then
        send_tg "📨 continuation → thread #$smart (smart-default: only recent pending parent; <code>/new</code> to override, <code>/use N</code> to switch)"
      else
        send_tg "📨 dispatched (orchestrator will read context and decide: new thread vs continue)"
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

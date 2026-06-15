#!/usr/bin/env bash
# worktree-janitor.sh — periodic TTL-based cleanup of orphan claude worktrees.
#
# Catch-all for the worktree-sprawl problem that Path 1 (maw --resume) and
# Path 2 (auto-clean on thread close) don't fully cover: long-running
# threads, manual ops, ad-hoc wakes, anything that escapes the directed-
# inbox lifecycle. Scans every repo enrolled below, classifies each
# worktree into one of three buckets, and either deletes (auto-safe class)
# or alerts (needs-review / lost-work classes).
#
# Classification:
#
#   auto-safe     age >7d + clean + pushed + claude dead + no inbox state
#                 → silent retire (kill window, git worktree remove,
#                                   git branch -d)
#
#   needs-review  age >7d + (uncommitted OR unpushed) + claude dead
#                 → daily Telegram alert; never auto-delete
#
#   lost-work     age >30d + uncommitted + unpushed
#                 → high-priority Telegram alert; never auto-delete
#                   (the "vigilant-almeida" pattern brew-ops surfaced)
#
# Skip (always KEEP):
#   - Main repo dir (not a worktree)
#   - Any wt where a claude process has wt_path as its cwd
#   - Any wt referenced by an inbox-watcher state file
#
# Default safety mode: DRY-RUN. Pass `auto` (or set JANITOR_AUTO=1) to
# perform retire actions. Even with auto, only auto-safe class is
# deleted — needs-review and lost-work always require human action.
#
# State at ~/.cache/worktree-janitor/.

set -u
exec </dev/null

ENV_FILE=${ENV_FILE:-$HOME/.cache/orchestrator-bot/.env}
[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }

STATE_DIR=${STATE_DIR:-$HOME/.cache/worktree-janitor}
mkdir -p "$STATE_DIR"
LOG_FILE=${LOG_FILE:-$STATE_DIR/janitor.log}
PID_FILE=${PID_FILE:-$STATE_DIR/janitor.pid}
LAST_ALERT_DIR=$STATE_DIR/last-alert
mkdir -p "$LAST_ALERT_DIR"

JANITOR_AUTO=${JANITOR_AUTO:-0}
SCAN_INTERVAL=${SCAN_INTERVAL:-14400}                  # 4h
AUTO_SAFE_AGE_DAYS=${AUTO_SAFE_AGE_DAYS:-7}
LOST_WORK_AGE_DAYS=${LOST_WORK_AGE_DAYS:-30}
ALERT_REPEAT_HOURS=${ALERT_REPEAT_HOURS:-24}            # repeat alerts at most once/day
INBOX_WATCHER_STATE=${INBOX_WATCHER_STATE:-$HOME/.cache/inbox-watcher/state}

# Repos enrolled for scanning. Each line: <main-repo-path>. Worktrees of
# this repo are siblings of the main path (`<repo>.wt-N-<suffix>` next to
# `<repo>` itself). Override via `JANITOR_REPOS` (newline-separated).
DEFAULT_REPOS=$(cat <<EOF
$HOME/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
$HOME/Code/github.com/kxlahsimx09/mb-next-payment-gateway
$HOME/Code/github.com/kokarat/mobiz-payment-gateway
$HOME/Code/github.com/kokarat/bank-bot
EOF
)
JANITOR_REPOS=${JANITOR_REPOS:-$DEFAULT_REPOS}

# ── helpers ────────────────────────────────────────────────────────────────

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

send_tg() {
  local text="$1"
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ] && {
    log "send_tg skipped (no TG creds in env)"
    return
  }
  if [ ${#text} -gt 3900 ]; then text="${text:0:3850}

[…truncated]"; fi
  curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$text" >/dev/null 2>&1 \
    || log "send_tg failed"
}

# Emit alert at most once per ALERT_REPEAT_HOURS for a given key.
alert_throttled() {
  local key=$1 text=$2
  local f="$LAST_ALERT_DIR/$key"
  local now=$(date +%s)
  if [ -f "$f" ]; then
    local last=$(cat "$f" 2>/dev/null || echo 0)
    local age=$((now - last))
    [ "$age" -lt $((ALERT_REPEAT_HOURS * 3600)) ] && return
  fi
  send_tg "$text"
  echo "$now" > "$f"
}

age_days() {
  local path=$1
  local mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null)
  [ -z "$mtime" ] && { echo 0; return; }
  echo $(( ($(date +%s) - mtime) / 86400 ))
}

claude_alive_at() {
  local wt=$1
  [ -z "$wt" ] && return 1
  pgrep -f "claude " 2>/dev/null | while read -r pid; do
    local pcwd
    pcwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ "$pcwd" = "$wt" ] && { echo alive; return; }
  done | grep -q alive
}

referenced_by_inbox_state() {
  local wt=$1
  [ ! -d "$INBOX_WATCHER_STATE" ] && return 1
  grep -rqlF "wt_path=$wt" "$INBOX_WATCHER_STATE" 2>/dev/null
}

# ── scan + classify ───────────────────────────────────────────────────────

scan_repo() {
  local repo=$1
  [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ] && {
    log "skip $repo (not a git repo)"
    return
  }

  local parent=$(dirname "$repo")
  local name=$(basename "$repo")

  # Worktrees match: <name>.wt-<N>-<suffix>
  local wts=()
  while IFS= read -r d; do
    [ -d "$d" ] && wts+=("$d")
  done < <(find "$parent" -maxdepth 1 -type d -name "${name}.wt-*" 2>/dev/null)

  [ ${#wts[@]} -eq 0 ] && return

  log "scan $repo (${#wts[@]} worktree(s))"

  for wt in "${wts[@]}"; do
    classify_and_act "$wt" "$repo"
  done
}

classify_and_act() {
  local wt=$1 repo=$2
  local age=$(age_days "$wt")
  local alive=0; claude_alive_at "$wt" && alive=1
  local in_use=0; referenced_by_inbox_state "$wt" && in_use=1

  # Always KEEP if claude alive or referenced
  if [ "$alive" = "1" ] || [ "$in_use" = "1" ]; then
    log "  KEEP $wt (age=${age}d, alive=$alive, in_use=$in_use)"
    return
  fi

  local dirty=0 unpushed=0
  [ -n "$(git -C "$wt" status --short 2>/dev/null | head -1)" ] && dirty=1
  [ -n "$(git -C "$wt" log '@{u}..' --oneline 2>/dev/null | head -1)" ] && unpushed=1

  # Lost-work: oldest + dirty + unpushed
  if [ "$age" -ge "$LOST_WORK_AGE_DAYS" ] && [ "$dirty" = "1" ] && [ "$unpushed" = "1" ]; then
    local key="lost-$(echo "$wt" | sed 's|/|_|g')"
    log "  LOST-WORK $wt (age=${age}d, dirty + unpushed)"
    alert_throttled "$key" "🔴 <b>worktree-janitor — LOST-WORK</b>
<code>$(echo "$wt" | html_escape)</code>
age: ${age}d · dirty: yes · unpushed: yes
Inspect before deciding. Never auto-delete."
    return
  fi

  # Needs-review: dirty OR unpushed
  if [ "$age" -ge "$AUTO_SAFE_AGE_DAYS" ] && { [ "$dirty" = "1" ] || [ "$unpushed" = "1" ]; }; then
    local why=""
    [ "$dirty" = "1" ] && why="${why}dirty "
    [ "$unpushed" = "1" ] && why="${why}unpushed"
    local key="review-$(echo "$wt" | sed 's|/|_|g')"
    log "  NEEDS-REVIEW $wt (age=${age}d, $why)"
    alert_throttled "$key" "⚠️ <b>worktree-janitor — needs-review</b>
<code>$(echo "$wt" | html_escape)</code>
age: ${age}d · $why"
    return
  fi

  # Auto-safe: old + clean + pushed
  if [ "$age" -ge "$AUTO_SAFE_AGE_DAYS" ] && [ "$dirty" = "0" ] && [ "$unpushed" = "0" ]; then
    log "  AUTO-SAFE $wt (age=${age}d, clean + pushed)"
    if [ "$JANITOR_AUTO" = "1" ]; then
      retire_worktree "$wt" "$repo"
    else
      log "    (DRY-RUN — set JANITOR_AUTO=1 to retire)"
    fi
    return
  fi

  # Young + healthy
  log "  KEEP $wt (age=${age}d, dirty=$dirty, unpushed=$unpushed)"
}

retire_worktree() {
  local wt=$1 repo=$2
  local branch
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)

  if git -C "$repo" worktree remove "$wt" 2>>"$LOG_FILE"; then
    log "    ✓ retired $wt"
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] && \
      git -C "$repo" branch -d "$branch" 2>/dev/null && \
      log "    ✓ deleted branch $branch"
  else
    log "    ✗ git worktree remove failed for $wt"
  fi
}

# ── main loop ──────────────────────────────────────────────────────────────

scan_once() {
  log "janitor scan starting (auto=$JANITOR_AUTO, threshold=${AUTO_SAFE_AGE_DAYS}d)"
  echo "$JANITOR_REPOS" | while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    scan_repo "$repo"
  done
  log "janitor scan complete"
}

run_loop() {
  log "worktree-janitor starting (interval=${SCAN_INTERVAL}s, auto=$JANITOR_AUTO)"
  while true; do
    scan_once
    sleep "$SCAN_INTERVAL"
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
      p=$(cat "$PID_FILE")
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
    echo "auto: $JANITOR_AUTO"
    echo "thresholds: auto-safe ${AUTO_SAFE_AGE_DAYS}d · lost-work ${LOST_WORK_AGE_DAYS}d"
    echo "alerts (last):"
    find "$LAST_ALERT_DIR" -type f -mtime -7 2>/dev/null | head -10
    ;;
  scan-once)
    scan_once
    ;;
  auto)
    JANITOR_AUTO=1 scan_once
    ;;
  *)
    cat <<USAGE >&2
usage: $0 {loop|start|stop|status|scan-once|auto}
  loop / start  daemon mode — scan every \$SCAN_INTERVAL (${SCAN_INTERVAL}s)
  stop          kill running daemon
  status        pid + thresholds + recent alerts
  scan-once     single scan, dry-run (no deletes)
  auto          single scan, retires auto-safe class

env: JANITOR_AUTO=1, SCAN_INTERVAL, AUTO_SAFE_AGE_DAYS, LOST_WORK_AGE_DAYS,
     ALERT_REPEAT_HOURS, JANITOR_REPOS (newline-separated paths),
     INBOX_WATCHER_STATE, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
USAGE
    exit 2
    ;;
esac

#!/usr/bin/env bash
# inbox-watcher.sh — pull-pattern receiver for the directed-inbox protocol
# (AGENTS.md §11 in the central vault). Polls
# ~/.arra-oracle-v2/ψ/inbox/for-{oracle}/ directories for new envelope files,
# fires `maw wake <oracle> --fresh --task "inbox: <fname>"` per Phase 2a, then
# verifies delivery + processing in three gates so silent-fails don't
# accumulate invisibly.
#
# Companion to scripts/w2-watcher.sh (commit-driven workflow trigger). This
# one is envelope-driven for cross-oracle communication.
#
# State machine per envelope (§11i in AGENTS.md):
#
#   NEW (no state file)                  → fire_wake → fired
#   fired (T1: claude/JSONL has prompt)  → verified  (capture session-id)
#   fired (T1 deadline elapsed)          → failed_no_prompt + alert
#   verified (T2: file moved out of root)→ completed
#   verified (T2 deadline elapsed)       → failed_stuck + alert
#   completed | failed_*                 (terminal — kept for audit)
#
# Layout:
#   ~/.cache/inbox-watcher/
#   ├── inbox-watcher.log              (rotating-by-restart log)
#   ├── inbox-watcher.pid
#   ├── state/<oracle>/<fname>.state    (per-envelope state machine)
#   └── sessions/<oracle>/thread-<N>.session-id  (per-thread session capture)
#
# Usage:
#   bash inbox-watcher.sh                 # foreground (interactive log to stdout)
#   bash inbox-watcher.sh start           # background-style (tail the log file)
#   bash inbox-watcher.sh stop
#   bash inbox-watcher.sh status
#   bash inbox-watcher.sh scan-once       # one pass, exit (useful for tests)
#
# Env overrides:
#   INBOX_BASE                  ~/.arra-oracle-v2/ψ/inbox
#   STATE_DIR                   ~/.cache/inbox-watcher
#   INBOX_POLL_INTERVAL         60        (seconds between scans)
#   T1_DELIVERY_DEADLINE        60        (s) deadline for prompt-in-JSONL
#   T2_PROCESSING_DEADLINE      1800      (s, 30m) deadline for archive
#   INBOX_SCAN_ENABLED          1         (set 0 to keep daemon alive but no-op)
#   MAW_BIN                     auto-detect (`maw` on PATH, else local cli.ts)

set -u
exec </dev/null   # detach from any inherited tty (defensive — see w2-watcher)

# ─── Config ────────────────────────────────────────────────────────────────

INBOX_BASE=${INBOX_BASE:-$HOME/.arra-oracle-v2/ψ/inbox}
STATE_DIR=${STATE_DIR:-$HOME/.cache/inbox-watcher}
LOG_FILE=${LOG_FILE:-$STATE_DIR/inbox-watcher.log}
PID_FILE=${PID_FILE:-$STATE_DIR/inbox-watcher.pid}

INBOX_POLL_INTERVAL=${INBOX_POLL_INTERVAL:-60}
T1_DELIVERY_DEADLINE=${T1_DELIVERY_DEADLINE:-60}
T2_PROCESSING_DEADLINE=${T2_PROCESSING_DEADLINE:-1800}
INBOX_SCAN_ENABLED=${INBOX_SCAN_ENABLED:-1}
# Path 2 — auto-clean: when an envelope reaches `completed` AND its thread is
# `closed` AND every safety gate passes, retire the worktree + claude session
# that handled it. Default OFF — opt in via env. See safe_to_retire() below.
INBOX_AUTO_CLEAN=${INBOX_AUTO_CLEAN:-0}
ORACLE_API=${ORACLE_API:-http://localhost:47778/api}
MAW_BIN=${MAW_BIN:-bun /Users/dev01/Code/github.com/Soul-Brews-Studio/maw-js/src/cli.ts}

CLAUDE_PROJECTS=${CLAUDE_PROJECTS:-$HOME/.claude/projects}

# Resolve maw binary: prefer PATH-resolved `maw`, else direct bun invocation
# of the local maw-js source tree (matches the dev01 ghq layout).
if command -v maw >/dev/null 2>&1; then
  MAW_BIN=${MAW_BIN:-maw}
else
  MAW_LOCAL=${MAW_LOCAL:-$HOME/Code/github.com/Soul-Brews-Studio/maw-js/src/cli.ts}
  MAW_BIN=${MAW_BIN:-bun $MAW_LOCAL}
fi

mkdir -p "$STATE_DIR/state" "$STATE_DIR/sessions"

# ─── Helpers ───────────────────────────────────────────────────────────────

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

alert() {
  log "ALERT: $*"
  # Phase 3 hook: telegram_send / detector marker write goes here.
}

# claude encodes cwd by replacing / and . with -
encode_cwd() { printf '%s' "$1" | sed 's|[/.]|-|g'; }

state_path() { printf '%s/state/%s/%s.state' "$STATE_DIR" "$1" "$2"; }

read_state() {
  local f=$1
  [ -f "$f" ] || return 1
  # shellcheck disable=SC1090
  source "$f"
}

write_state() {
  local f=$1
  shift
  mkdir -p "$(dirname "$f")"
  : >"$f"
  for kv in "$@"; do printf '%s\n' "$kv" >>"$f"; done
}

set_state_field() {
  local f=$1 key=$2 val=$3
  if grep -q "^$key=" "$f" 2>/dev/null; then
    # macOS sed: -i '' is required; skip the .bak dance
    local tmp=$f.tmp
    awk -v k="$key" -v v="$val" -F= '
      BEGIN{OFS="="}
      $1==k {print $1,v; next}
      {print}
    ' "$f" >"$tmp" && mv "$tmp" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >>"$f"
  fi
}

# Match a JSONL line that has a user message containing the inbox filename
# (the prompt we sent via --task). Robust to JSON whitespace + quoting.
jsonl_has_prompt() {
  local jsonl=$1 fname=$2
  [ -f "$jsonl" ] || return 1
  grep -qF "inbox: $fname" "$jsonl" 2>/dev/null
}

# ─── State transitions ─────────────────────────────────────────────────────

fire_wake() {
  local oracle=$1 file=$2 fname=$3
  local thread_id wake_ts wt_suffix sf wake_out wt_path

  thread_id=$(grep '^thread:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  wake_ts=$(date +%s)
  wt_suffix=inbox-$wake_ts
  sf=$(state_path "$oracle" "$fname")

  # Write state BEFORE firing — prevents double-fire if next scan races us.
  write_state "$sf" \
    "fired_at=$wake_ts" \
    "oracle=$oracle" \
    "fname=$fname" \
    "thread_id=$thread_id" \
    "wt_suffix=$wt_suffix" \
    "status=fired"

  log "[$oracle] $fname → fire (thread=$thread_id, suffix=$wt_suffix)"

  # Capture maw wake output to extract the resolved worktree path.
  # `maw wake` is synchronous-ish: it returns after spawning, but claude itself
  # runs async inside the tmux pane. We don't block on claude — verify_delivery
  # will pick up the JSONL on the next scan tick.
  wake_out=$($MAW_BIN wake "$oracle" --fresh --wt "$wt_suffix" --no-attach \
    --task "inbox: $fname" 2>&1) || {
    set_state_field "$sf" status fire_failed
    set_state_field "$sf" failed_at "$(date +%s)"
    alert "[$oracle] maw wake exit nonzero for $fname: $(printf '%s' "$wake_out" | tail -3 | tr '\n' ' ')"
    return 1
  }
  printf '%s\n' "$wake_out" >>"$LOG_FILE"

  # `+ worktree: /path/to/repo.wt-N-suffix (branch)` — extract path.
  # maw output has ANSI color codes (e.g. ESC[32m+ESC[0m worktree:), so we
  # strip them before extracting. sed pattern matches the path token after
  # `worktree: ` and stops at the first whitespace.
  wt_path=$(printf '%s' "$wake_out" \
    | sed -E 's/\x1b\[[0-9;]*m//g' \
    | grep -o 'worktree: [^ ]*' \
    | head -1 \
    | awk '{print $2}')
  [ -n "$wt_path" ] && set_state_field "$sf" wt_path "$wt_path"
}

verify_delivery() {
  local sf=$1
  read_state "$sf" || return 0
  local now age proj_dir jsonl sid sids_dir
  now=$(date +%s)
  age=$((now - fired_at))

  if [ -n "${wt_path:-}" ]; then
    proj_dir=$CLAUDE_PROJECTS/$(encode_cwd "$wt_path")
    if [ -d "$proj_dir" ]; then
      jsonl=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1)
      if [ -n "$jsonl" ] && jsonl_has_prompt "$jsonl" "$fname"; then
        sid=$(basename "$jsonl" .jsonl)
        if [ -n "${thread_id:-}" ] && [ "$thread_id" != "" ]; then
          sids_dir=$STATE_DIR/sessions/$oracle
          mkdir -p "$sids_dir"
          printf '%s\n' "$sid" >"$sids_dir/thread-$thread_id.session-id"
        fi
        set_state_field "$sf" status verified
        set_state_field "$sf" verified_at "$now"
        set_state_field "$sf" session_id "$sid"
        log "[$oracle] $fname VERIFIED (sid=$sid, thread=$thread_id, age=${age}s)"
        return 0
      fi
    fi
  fi

  if [ "$age" -ge "$T1_DELIVERY_DEADLINE" ]; then
    set_state_field "$sf" status failed_no_prompt
    set_state_field "$sf" failed_at "$now"
    alert "[$oracle] $fname FAILED — no prompt in JSONL after ${T1_DELIVERY_DEADLINE}s (wt=${wt_path:-?})"
  fi
}

verify_processing() {
  local sf=$1 file=$2
  read_state "$sf" || return 0
  local now age
  now=$(date +%s)
  age=$((now - fired_at))

  if [ ! -f "$file" ]; then
    set_state_field "$sf" status completed
    set_state_field "$sf" completed_at "$now"
    log "[$oracle] $fname COMPLETED (archived; age=${age}s)"
    [ "$INBOX_AUTO_CLEAN" = "1" ] && maybe_retire_worktree "$sf"
    return 0
  fi

  if [ "$age" -ge "$T2_PROCESSING_DEADLINE" ]; then
    set_state_field "$sf" status failed_stuck
    set_state_field "$sf" failed_at "$now"
    alert "[$oracle] $fname STUCK — file still in inbox after $((T2_PROCESSING_DEADLINE / 60))min"
  fi
}

# ─── Path 2 — auto-clean when thread closes ────────────────────────────────

# Query oracle API for thread status; echoes 'closed'|'active'|'pending'|''.
thread_status() {
  local id=$1
  [ -z "$id" ] && { echo ""; return; }
  curl -sf -m 3 "$ORACLE_API/forum/thread/$id" 2>/dev/null \
    | jq -r '.thread.status // empty' 2>/dev/null
}

# True iff any other active state file (not $sf) references the same wt_path.
other_state_references_wt() {
  local sf=$1 wt=$2
  [ -z "$wt" ] && return 1
  for other in "$STATE_DIR"/state/*/*.state; do
    [ -f "$other" ] || continue
    [ "$other" = "$sf" ] && continue
    grep -q "^wt_path=$wt$" "$other" && return 0
  done
  return 1
}

# True iff any claude process is currently running with $wt_path as its cwd.
claude_alive_at() {
  local wt=$1
  [ -z "$wt" ] && return 1
  pgrep -f "claude " 2>/dev/null | while read -r pid; do
    local pcwd
    pcwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ "$pcwd" = "$wt" ] && { echo alive; return; }
  done | grep -q alive
}

# Safety gates for retiring a worktree. Returns reason string on first
# failure (caller checks $? = 0 means safe). Empty string output means OK.
safe_to_retire() {
  local sf=$1
  read_state "$sf" || { echo "state-unreadable"; return 1; }

  [ -z "${wt_path:-}" ] && { echo "no-wt-path"; return 1; }
  [ ! -d "$wt_path" ] && { echo "wt-already-gone"; return 1; }

  local ts
  ts=$(thread_status "${thread_id:-}")
  [ "$ts" != "closed" ] && { echo "thread-${thread_id:-?}-not-closed-($ts)"; return 1; }

  # git: clean working tree + all commits pushed
  local dirty
  dirty=$(git -C "$wt_path" status --short 2>/dev/null | head -1)
  [ -n "$dirty" ] && { echo "wt-dirty"; return 1; }

  local unpushed
  unpushed=$(git -C "$wt_path" log '@{u}..' --oneline 2>/dev/null | head -1)
  [ -n "$unpushed" ] && { echo "wt-has-unpushed-commits"; return 1; }

  claude_alive_at "$wt_path" && { echo "claude-still-alive"; return 1; }

  other_state_references_wt "$sf" "$wt_path" && { echo "wt-shared-by-other-envelope"; return 1; }

  echo ""
  return 0
}

# Try to retire the worktree associated with $sf if all gates pass.
maybe_retire_worktree() {
  local sf=$1
  read_state "$sf" || return 0

  local reason
  reason=$(safe_to_retire "$sf")
  if [ -n "$reason" ]; then
    log "[$oracle] $fname retire SKIPPED ($reason)"
    return 0
  fi

  # All gates pass — perform the retire.
  local repo_path branch
  repo_path=$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null)
  branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null)

  # Best-effort kill the tmux window for this wake (non-fatal if gone).
  $MAW_BIN ls 2>/dev/null | grep -q "${wt_suffix:-__none__}" && {
    $MAW_BIN kill "*:*${wt_suffix}*" 2>/dev/null || true
  }

  # git worktree remove (refuses on dirty by default — safe)
  if git -C "$wt_path/.." worktree remove "$wt_path" 2>>"$LOG_FILE"; then
    log "[$oracle] $fname RETIRED worktree $wt_path"
    # Best-effort branch delete (only succeeds if merged or no unique commits)
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] && \
      git -C "$repo_path" branch -d "$branch" 2>/dev/null && \
      log "[$oracle] retired branch $branch"
    set_state_field "$sf" retired_at "$(date +%s)"
  else
    log "[$oracle] $fname retire FAILED (git worktree remove returned nonzero — keeping)"
  fi
}

# ─── Scan loop ─────────────────────────────────────────────────────────────

scan_inbox() {
  local oracle_dir oracle file fname sf state_dir

  # Pass 1 — iterate inbox dirs for NEW envelopes + in-progress ones.
  for oracle_dir in "$INBOX_BASE"/for-*/; do
    [ -d "$oracle_dir" ] || continue
    oracle=$(basename "$oracle_dir" | sed 's/^for-//')
    [ "$oracle" = "*" ] && continue

    for file in "$oracle_dir"*.md; do
      [ -f "$file" ] || continue
      fname=$(basename "$file")
      [ "$fname" = ".gitkeep" ] && continue

      sf=$(state_path "$oracle" "$fname")

      if [ ! -f "$sf" ]; then
        fire_wake "$oracle" "$file" "$fname"
      else
        # shellcheck disable=SC1090
        source "$sf"
        case "${status:-unknown}" in
          fired)              verify_delivery "$sf" ;;
          verified)           verify_processing "$sf" "$file" ;;
          completed|failed_*|fire_failed) : ;;  # terminal
          *)                  alert "[$oracle] $fname unknown status=$status" ;;
        esac
      fi
    done
  done

  # Pass 2 — iterate state files for verified envelopes whose backing file
  # has been archived (moved out of the inbox root). Pass 1 misses these
  # because it only sees files currently in for-{oracle}/, so a verified
  # envelope that was archived between two scans never transitions to
  # `completed` without this pass.
  for state_dir in "$STATE_DIR"/state/*/; do
    [ -d "$state_dir" ] || continue
    oracle=$(basename "$state_dir")
    [ "$oracle" = "*" ] && continue

    for sf in "$state_dir"*.state; do
      [ -f "$sf" ] || continue
      # shellcheck disable=SC1090
      source "$sf"
      [ "${status:-}" = "verified" ] || continue
      file="$INBOX_BASE/for-$oracle/$fname"
      [ ! -f "$file" ] && verify_processing "$sf" "$file"
    done
  done
}

run_loop() {
  log "inbox-watcher start (interval=${INBOX_POLL_INTERVAL}s, T1=${T1_DELIVERY_DEADLINE}s, T2=${T2_PROCESSING_DEADLINE}s, enabled=$INBOX_SCAN_ENABLED)"
  while true; do
    if [ "$INBOX_SCAN_ENABLED" = "1" ]; then
      scan_inbox || log "scan_inbox returned nonzero (continuing)"
    fi
    sleep "$INBOX_POLL_INTERVAL"
  done
}

# ─── CLI ───────────────────────────────────────────────────────────────────

case ${1:-loop} in
  loop|start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "already running: $(cat "$PID_FILE")" >&2
      exit 1
    fi
    printf '%d\n' "$$" >"$PID_FILE"
    trap 'rm -f "$PID_FILE"; exit 0' INT TERM
    run_loop
    ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      p=$(cat "$PID_FILE")
      if kill -TERM "$p" 2>/dev/null; then
        echo "stopped pid=$p"
      else
        echo "kill failed (process gone?)" >&2
      fi
      rm -f "$PID_FILE"
    else
      echo "not running"
    fi
    ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "running: $(cat "$PID_FILE")"
    else
      echo "stopped"
    fi
    echo
    echo "envelope state files:"
    if [ -d "$STATE_DIR/state" ]; then
      find "$STATE_DIR/state" -name '*.state' -type f 2>/dev/null | while read -r f; do
        st=$(grep '^status=' "$f" | tail -1 | cut -d= -f2)
        printf '  %-12s  %s\n' "$st" "${f#"$STATE_DIR/state/"}"
      done
    fi
    echo
    echo "session-id mappings:"
    if [ -d "$STATE_DIR/sessions" ]; then
      find "$STATE_DIR/sessions" -name 'thread-*.session-id' -type f 2>/dev/null | while read -r f; do
        printf '  %s → %s\n' "${f#"$STATE_DIR/sessions/"}" "$(cat "$f")"
      done
    fi
    ;;
  scan-once)
    log "scan-once (single pass)"
    scan_inbox
    ;;
  *)
    cat <<USAGE >&2
usage: $0 {loop|start|stop|status|scan-once}
  loop / start  run the watcher daemon (foreground)
  stop          kill a running daemon by pid file
  status        show pid + per-envelope state + session-id mappings
  scan-once     single scan pass (no loop) — for tests
env overrides: INBOX_BASE, STATE_DIR, LOG_FILE, INBOX_POLL_INTERVAL,
               T1_DELIVERY_DEADLINE, T2_PROCESSING_DEADLINE,
               INBOX_SCAN_ENABLED, MAW_BIN, CLAUDE_PROJECTS
USAGE
    exit 2
    ;;
esac

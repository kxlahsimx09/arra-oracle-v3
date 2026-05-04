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
# Phase 6 — claude_alive_at heuristic. A claude process is "active" only if
# its cwd matches the worktree AND its JSONL has been written within this
# many seconds. Older = "stuck" (likely zombie subshell from a prior wake
# whose `claude --resume -p` parent exited but children remain), so Path 1
# can safely resume past it. Tune up if false-positive resumes hit busy
# claudes that pause >5min between tool calls.
CLAUDE_STUCK_TIMEOUT=${CLAUDE_STUCK_TIMEOUT:-300}

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

# Phase 7 — cancel envelope detection. A cancel envelope is one whose
# filename ends in `_cancel.md` OR whose frontmatter sets `user_action:
# cancel`. The bot's /cancel command produces both signals. Cancel
# envelopes get priority handling in fire_wake — see preempt_claude_at.
is_cancel_envelope() {
  local file=$1
  [[ "$(basename "$file")" == *_cancel.md ]] && return 0
  grep -q '^user_action: *cancel' "$file" 2>/dev/null && return 0
  return 1
}

# Phase 7 — list claude pids whose cwd matches wt. Used by claude_alive_at
# (single-pid lookup) and preempt_claude_at (kill all).
claude_pids_at() {
  local wt=$1
  [ -z "$wt" ] && return
  pgrep -f "claude " 2>/dev/null | while read -r pid; do
    local pcwd
    pcwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ "$pcwd" = "$wt" ] && echo "$pid"
  done
}

# Phase 7 — pre-empt all claude processes at wt (used when a cancel
# envelope races with an active wake on the same thread). TERM first,
# then KILL stragglers after a brief grace period. Logs each kill so an
# operator can see what was reaped.
preempt_claude_at() {
  local wt=$1
  [ -z "$wt" ] && return 0
  local pids
  pids=$(claude_pids_at "$wt")
  [ -z "$pids" ] && return 0

  for pid in $pids; do
    if kill -TERM "$pid" 2>/dev/null; then
      log "  TERM pid=$pid (cwd=$wt)"
    fi
  done
  sleep 2
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null && log "  KILL pid=$pid (still alive after TERM)"
    fi
  done
}

# Path 1 helpers — find a prior wt_path that handled a given thread for an
# oracle. Reads the most-recent state file for that (oracle, thread) tuple
# (whether `completed` or terminal-success) — its wt_path is the candidate
# for --resume reuse.
find_prior_wt_for_thread() {
  local oracle=$1 thread_id=$2
  [ -z "$thread_id" ] && return 1
  local state_dir="$STATE_DIR/state/$oracle"
  [ ! -d "$state_dir" ] && return 1
  # Newest state file first; pick the first one whose thread_id + wt_path match.
  local latest
  latest=$(ls -t "$state_dir"/*.state 2>/dev/null | while read -r f; do
    grep -q "^thread_id=$thread_id$" "$f" 2>/dev/null && echo "$f"
  done | head -1)
  [ -z "$latest" ] && return 1
  grep '^wt_path=' "$latest" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Reused by Path 2 (maybe_retire_worktree) and Path 1 (fire_wake's resume gate).
# Returns 0 (true) iff a claude process is **actively** working in `wt` —
# distinguishing three states:
#
#   active  process alive AT cwd=wt AND JSONL written within
#           CLAUDE_STUCK_TIMEOUT seconds → block reuse (parallel work case)
#   stuck   process alive AT cwd=wt BUT JSONL idle > timeout → allow reuse
#           (zombie subshell pattern: `claude --resume -p` parent exits but
#            child shell scripts linger holding the cwd open; happens with
#            bash tool-call subshells. Treating stuck as "alive" was the
#            Phase 5 bug that made Path 1 spawn wt-15 instead of resuming
#            wt-12 on 2026-05-03 20:49.)
#   dead    no claude process at cwd=wt → allow reuse
#
# Returns 0 only for `active`. `stuck` and `dead` both return 1.
claude_alive_at() {
  local wt=$1
  [ -z "$wt" ] && return 1

  # Step 1 — find candidate pids whose cwd matches wt.
  local found_pid=""
  while read -r pid; do
    local pcwd
    pcwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    if [ "$pcwd" = "$wt" ]; then
      found_pid=$pid
      break
    fi
  done < <(pgrep -f "claude " 2>/dev/null)

  [ -z "$found_pid" ] && return 1   # dead — no process at cwd

  # Step 2 — process exists; check if any JSONL under the project dir has
  # been written recently. A genuinely-active claude writes tool_use /
  # tool_result / text turns continuously; a stuck zombie does not.
  local proj_dir="$CLAUDE_PROJECTS/$(encode_cwd "$wt")"
  if [ ! -d "$proj_dir" ]; then
    # Process alive but no project dir — anomalous. Treat as stuck.
    log "claude_alive_at($wt) → pid=$found_pid alive but no project dir; STUCK"
    return 1
  fi

  local newest_mtime now age
  newest_mtime=$(stat -f %m "$proj_dir"/*.jsonl 2>/dev/null | sort -nr | head -1)
  if [ -z "$newest_mtime" ]; then
    log "claude_alive_at($wt) → pid=$found_pid alive but no JSONL; STUCK"
    return 1
  fi
  now=$(date +%s)
  age=$((now - newest_mtime))

  if [ "$age" -gt "$CLAUDE_STUCK_TIMEOUT" ]; then
    log "claude_alive_at($wt) → pid=$found_pid alive but JSONL idle ${age}s > ${CLAUDE_STUCK_TIMEOUT}s; STUCK (resume OK)"
    return 1
  fi

  # active
  return 0
}

# ─── State transitions ─────────────────────────────────────────────────────

fire_wake() {
  local oracle=$1 file=$2 fname=$3
  local thread_id wake_ts wt_suffix sf wake_out wt_path
  local sid_file prior_sid prior_wt resume_sid wt_arg

  thread_id=$(grep '^thread:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  wake_ts=$(date +%s)
  wt_suffix=inbox-$wake_ts
  sf=$(state_path "$oracle" "$fname")

  # Phase 7 — cancel pre-emption. Cancel envelopes are priority-1: if
  # there's an active claude in a prior worktree for the same thread, kill
  # it before firing the cancel handler. Without this, the cancel races
  # against the work being cancelled, and the active wake can complete a
  # destructive dispatch (e.g. write envelope to brew-ops) seconds before
  # the cancel handler even reads its own envelope. Observed live
  # 2026-05-04 10:48: continuation envelope for thread #63 fired into
  # wt-8, dispatched sub-thread #65 to brew-ops, then user cancel arrived
  # — by the time wt-16 (cancel handler) closed #63, the dispatch envelope
  # for brew-ops had already been picked up by the inbox-watcher and was
  # processed in wt-17. Pre-empting wt-8 the moment the cancel envelope
  # lands prevents the dispatch from going out in the first place.
  #
  # Cancel envelopes deliberately do NOT take the Path 1 --resume route
  # below: the cancel handler runs on a fresh wake (no prior context
  # needed — it just closes the thread and archives) so the prior session
  # being killed here doesn't matter.
  if [ -n "$thread_id" ] && is_cancel_envelope "$file"; then
    local cancel_prior_wt
    cancel_prior_wt=$(find_prior_wt_for_thread "$oracle" "$thread_id")
    if [ -n "$cancel_prior_wt" ] && [ -d "$cancel_prior_wt" ] \
       && [ -n "$(claude_pids_at "$cancel_prior_wt")" ]; then
      log "[$oracle] CANCEL PRE-EMPT — terminating claude(s) at $cancel_prior_wt for thread $thread_id"
      preempt_claude_at "$cancel_prior_wt"
    fi
  fi

  # Path 1 — worktree reuse via maw --resume. If we already have a
  # session-id mapped for this (oracle, thread) AND no claude is currently
  # alive in the worktree that birthed it, resume that session in the SAME
  # worktree instead of spawning a fresh one. Drives worktree count toward
  # (oracle × thread) pairs rather than total wakes. Falls back to --fresh
  # silently if any precondition is missing.
  #
  # Skipped for cancel envelopes (handled above): cancel handler runs on
  # a fresh wake; prior session was just killed so resume would fail
  # anyway and the cancel doesn't need that context.
  if [ -n "$thread_id" ] && ! is_cancel_envelope "$file"; then
    sid_file="$STATE_DIR/sessions/$oracle/thread-$thread_id.session-id"
    if [ -f "$sid_file" ]; then
      prior_sid=$(cat "$sid_file")
      prior_wt=$(find_prior_wt_for_thread "$oracle" "$thread_id")
      if [ -n "$prior_sid" ] && [ -n "$prior_wt" ] && [ -d "$prior_wt" ] \
         && ! claude_alive_at "$prior_wt"; then
        resume_sid=$prior_sid
        # Re-use the existing wt_suffix so maw attaches to the same worktree
        # window. We extract it from the prior wt path: `<repo>.wt-<N>-<suffix>`.
        wt_suffix=$(basename "$prior_wt" | sed 's/^[^.]*\.wt-[0-9]*-//')
      fi
    fi
  fi

  # Write state BEFORE firing — prevents double-fire if next scan races us.
  write_state "$sf" \
    "fired_at=$wake_ts" \
    "oracle=$oracle" \
    "fname=$fname" \
    "thread_id=$thread_id" \
    "wt_suffix=$wt_suffix" \
    "status=fired"
  [ -n "${resume_sid:-}" ] && set_state_field "$sf" resume_sid "$resume_sid"

  log "[$oracle] $fname → fire (thread=$thread_id, suffix=$wt_suffix${resume_sid:+, RESUME sid=$resume_sid})"

  # Capture maw wake output to extract the resolved worktree path.
  if [ -n "${resume_sid:-}" ]; then
    wake_out=$($MAW_BIN wake "$oracle" --resume "$resume_sid" --wt "$wt_suffix" --no-attach \
      --task "inbox: $fname" 2>&1) || {
      set_state_field "$sf" status fire_failed
      set_state_field "$sf" failed_at "$(date +%s)"
      alert "[$oracle] maw wake --resume exit nonzero for $fname: $(printf '%s' "$wake_out" | tail -3 | tr '\n' ' ')"
      return 1
    }
  else
    wake_out=$($MAW_BIN wake "$oracle" --fresh --wt "$wt_suffix" --no-attach \
      --task "inbox: $fname" 2>&1) || {
      set_state_field "$sf" status fire_failed
      set_state_field "$sf" failed_at "$(date +%s)"
      alert "[$oracle] maw wake exit nonzero for $fname: $(printf '%s' "$wake_out" | tail -3 | tr '\n' ' ')"
      return 1
    }
  fi
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

# Find OTHER live daemon instances of this script (excluding $$).
# PID_FILE alone is insufficient — if removed manually (or by a crash that
# didn't trap) `start` would spawn a second instance alongside the first.
# Two watchers race on per-envelope state writes and can double-fire
# `maw wake`. Verified live 2026-05-04: PIDs 6687 + 66345 both running
# with no PID_FILE present.
#
# Match shape: cmdline starts with `bash` (or absolute bash) AND contains
# the script's basename. Skips transient `sh -c …basename…` children spawned
# by the very pipeline we're running here (their cmdline begins with `sh`).
find_other_daemons() {
  local base=$(basename "$0")
  local p cmd out=""
  for p in $(pgrep -f "$base" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    cmd=$(ps -p "$p" -o command= 2>/dev/null)
    case "$cmd" in
      bash" "*"$base"*|*/bash" "*"$base"*) out="$out $p" ;;
    esac
  done
  echo "${out# }"
}

case ${1:-loop} in
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
    printf '%d\n' "$$" >"$PID_FILE"
    # EXIT trap covers `set -e` aborts and clean exits; the explicit `exit 0`
    # for INT/TERM is preserved so a Ctrl-C unwinds without surfacing as error.
    trap 'rm -f "$PID_FILE"' EXIT
    trap 'rm -f "$PID_FILE"; exit 0' INT TERM
    run_loop
    ;;
  stop)
    # TERM all instances — PID_FILE may have drifted; we want a clean
    # teardown regardless. Best-effort.
    others=$(find_other_daemons)
    if [ -z "$others" ] && { [ ! -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }; then
      echo "not running"
      rm -f "$PID_FILE"
      exit 0
    fi
    [ -f "$PID_FILE" ] && others="$others $(cat "$PID_FILE" 2>/dev/null)"
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

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
#   NEW (campaign has a recorded owner    → §151 owner routing:
#        — thread #151)                     owner busy → deferred
#                                           owner idle → delivered_to_owner
#                                           owner down → fired (--resume)
#                                           owner gone → fired (--fresh)
#   NEW (envelope whose campaign already  → deferred  (queued behind the live
#        has a live/in-flight session                 campaign session; no
#        but no owner record — §11k/§153)             sibling spawned)
#   deferred (campaign/owner idle)       → fire_wake / fire_to_owner → fired
#   fired | delivered_to_owner            → verified  (T1: JSONL has prompt;
#                                           capture session-id)
#   fired | delivered_to_owner            → failed_no_prompt + alert
#        (T1 deadline elapsed)
#   verified (T2: file moved out of root)→ completed
#   verified (T2 deadline elapsed)       → failed_stuck + alert
#   completed | failed_*                 (terminal — kept for audit)
#
# §151 sticky thread→session ownership: the dispatcher stamps
# `parent_session: <its-worktree-path>` on outbound dispatch envelopes; the
# watcher records sessions/<parent_oracle>/thread-<parent_thread>.owner and
# routes every later reply for that campaign back to the OWNING session —
# send-keys into a live idle owner, --resume an idle-down one, --fresh +
# ownership transfer only if the owner worktree is gone.
#
# Wake key (§11f/§11k campaign session reuse): ANY envelope carrying a
# `parent_thread:` (a §11k fan-out sub-task envelope) keys the session map +
# worktree reuse on parent_thread — one session per oracle per campaign, not
# per sub-thread. For the orchestrator this converges a campaign's fan-out
# replies on ONE session instead of `--fresh`-spawning N parallel siblings
# that each re-dispatch the same follow-up (the 2026-05-16 triple-dispatch
# incident — PR #129/#130/#131 for one task; thread #134 / escalation #348).
# For worker agents (next-impl / next-writer / pg-writer / bot-writer /
# next-architect) it `--resume`s the agent's campaign session for each new
# sub-thread of an in-flight campaign rather than spawning a per-sub-thread
# session. New campaign (new parent_thread) = new session, so context stays
# campaign-scoped. Envelopes with no parent_thread key on their own `thread:`.
#
# Layout:
#   ~/.cache/inbox-watcher/
#   ├── inbox-watcher.log              (rotating-by-restart log)
#   ├── inbox-watcher.pid
#   ├── state/<oracle>/<fname>.state    (per-envelope state machine)
#   ├── sessions/<oracle>/thread-<K>.session-id  (per-wake-key session capture;
#   │                                      K = parent_thread for any fan-out
#   │                                      sub-task, else the envelope's thread)
#   └── sessions/<oracle>/thread-<K>.owner       (§151 campaign owner — the
#                                          dispatcher's worktree path, learned
#                                          from the dispatch envelope's
#                                          parent_session field)
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
#   INBOX_AUTO_CLEAN            1         (retire worktrees/sessions on close)
#   INBOX_GC_INTERVAL           600       (s) cadence of the campaign GC sweep
#   SESSION_TTL_DAYS            30        idle-days before a session-id is GC'd
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
# that handled it. Default ON — the safety gates ARE the conservatism (wt
# clean, pushed, claude dead, no other state references wt, thread closed).
# Set INBOX_AUTO_CLEAN=0 only if you need to inspect closed worktrees by hand.
INBOX_AUTO_CLEAN=${INBOX_AUTO_CLEAN:-1}
# Path 2b — periodic campaign GC sweep. Every INBOX_GC_INTERVAL seconds the
# watcher mops up what the per-envelope retire misses: completed envelopes
# whose thread closed AFTER completion, session-id cache files past their TTL,
# and crash-orphaned worktrees (no tmux window, no live claude, not referenced
# by any envelope state). This is the manual 47→5 worktree purge made routine.
# Gated by INBOX_AUTO_CLEAN like the per-envelope retire.
INBOX_GC_INTERVAL=${INBOX_GC_INTERVAL:-600}
# A session-id cache file not resumed for this many days is dropped (§11f TTL
# backstop — assume the campaign is cold). Retire-driven eviction handles the
# common case; the TTL covers campaigns whose thread never formally closed.
SESSION_TTL_DAYS=${SESSION_TTL_DAYS:-30}
ORACLE_API=${ORACLE_API:-http://localhost:47778/api}
MAW_BIN=${MAW_BIN:-bun /Users/dev01/Code/github.com/Soul-Brews-Studio/maw-js/src/cli.ts}
# Phase 6 — claude_alive_at heuristic. A claude process is "active" only if
# its cwd matches the worktree AND its JSONL has been written within this
# many seconds. Older = "stuck" (likely zombie subshell from a prior wake
# whose `claude --resume -p` parent exited but children remain), so Path 1
# can safely resume past it.
#
# Default 600s (10 min). Earlier 300s default tripped false positives on
# legitimate slow sessions: a claude waiting for a long `bun test` or a
# multi-step search can easily go 5-10 min between JSONL writes. 600s is
# more conservative; tune lower only if the operator actively wants to
# steal worktrees from slow-but-legitimate sessions.
CLAUDE_STUCK_TIMEOUT=${CLAUDE_STUCK_TIMEOUT:-600}

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
  # Write exactly ONE copy to $LOG_FILE. Echo to stderr only when stderr is a
  # terminal (interactive foreground run).
  #
  # The old form was `printf … | tee -a "$LOG_FILE" >&2`. A daemon launched the
  # conventional way — `nohup … >>"$LOG_FILE" 2>&1` — has fd 2 pointing back at
  # $LOG_FILE itself, so `tee` wrote the line once (tee→file) and `>&2` wrote it
  # a second time (tee's stdout→fd 2→same file). Every gc_sweep/scan/alert line
  # landed twice. Verified 2026-05-17: watcher pid 79344 had fd 1 AND fd 2 both
  # on inbox-watcher.log. The `[ -t 2 ]` guard keeps console echo for foreground
  # runs without ever double-writing the file.
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "$line" >>"$LOG_FILE"
  [ -t 2 ] && printf '%s\n' "$line" >&2
  return 0
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
# then KILL stragglers after a grace period long enough for a single
# tool call (Write / git commit / curl) to finish. Logs each kill so
# an operator can see what was reaped.
#
# Tunable via PREEMPT_GRACE_SEC (default 10). Original 2s was too short
# — a Write tool mid-flush would lose the file; a git commit mid-write
# would leave the index in a bad state. 10s gives single tool calls
# room to land while still bounding the cancel latency.
PREEMPT_GRACE_SEC=${PREEMPT_GRACE_SEC:-10}
preempt_claude_at() {
  local wt=$1
  [ -z "$wt" ] && return 0
  local pids
  pids=$(claude_pids_at "$wt")
  [ -z "$pids" ] && return 0

  # Diagnostic: log JSONL recency so an operator can tell whether the
  # claude was actively writing when we pre-empted.
  local proj_dir="$CLAUDE_PROJECTS/$(encode_cwd "$wt")"
  if [ -d "$proj_dir" ]; then
    local newest=$(stat -f %m "$proj_dir"/*.jsonl 2>/dev/null | sort -nr | head -1)
    if [ -n "$newest" ]; then
      local age=$(( $(date +%s) - newest ))
      log "  pre-empt context: JSONL idle ${age}s (>= grace = active mid-tool risk)"
    fi
  fi

  for pid in $pids; do
    if kill -TERM "$pid" 2>/dev/null; then
      log "  TERM pid=$pid (cwd=$wt) — grace ${PREEMPT_GRACE_SEC}s"
    fi
  done
  sleep "$PREEMPT_GRACE_SEC"
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null && log "  KILL pid=$pid (still alive after ${PREEMPT_GRACE_SEC}s grace)"
    fi
  done
}

# Wake key — the identity a wake is reused under (§11f session map, §11k
# campaign session reuse). ANY envelope that carries a `parent_thread:` (a
# §11k fan-out sub-task envelope) keys on parent_thread, so every sub-thread
# of one campaign maps to the SAME session for that oracle — one session per
# oracle per campaign, not per sub-thread.
#
#  - orchestrator: a campaign's fan-out replies converge on ONE orchestrator
#    session. Keying on the individual sub-thread instead — the pre-2026-05-16
#    behaviour — gave each reply its own session-id and so `--fresh`-spawned a
#    separate orchestrator session per reply; the siblings then each ran Step
#    0.5 and re-dispatched the same follow-up (triple-dispatch incident #348).
#  - worker agents (next-impl / next-writer / pg-writer / bot-writer /
#    next-architect): a new sub-thread of an in-flight campaign `--resume`s the
#    agent's campaign session (fire_wake Path 1) instead of `--fresh`-spawning
#    a per-sub-thread session — the per-thread sprawl source closed here. A new
#    campaign (new parent_thread) still gets a new session, so context stays
#    campaign-scoped: no cross-campaign bias bleed, parallelism across
#    campaigns preserved.
#
# Envelopes with no parent_thread (campaign-parent threads, standalone
# consults) key on their own `thread:` id, unchanged from §11f.
wake_key() {
  local file=$1 thread_id=$2
  local pt
  pt=$(grep '^parent_thread:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  [ -n "$pt" ] && { printf '%s' "$pt"; return 0; }
  printf '%s' "$thread_id"
}

# ─── Sticky thread→session ownership (thread #151) ─────────────────────────
#
# The watcher's session map only ever held sessions the watcher itself
# spawned (verify_delivery captures them). A thread opened *inside* an
# already-running session — via an arra_thread MCP call — produces no inbox
# event, so the watcher never learned that session owns it; the first reply
# for the campaign --fresh-spawned a new orchestrator that became de-facto
# owner (the #140/#141 context-fragmentation + session-sprawl).
#
# Fix: the dispatcher stamps `parent_session: <its-worktree-path>` on every
# OUTBOUND dispatch envelope. The watcher reads that field off the dispatch
# envelope (it scans every for-*/ dir anyway) and records
#   sessions/<parent_oracle>/thread-<parent_thread>.owner = <worktree path>
# Worker reply envelopes need NO new field — they already carry parent_thread
# (§11k). A reply for campaign N then routes back to N's owner: send-keys into
# a live idle owner window, --resume an idle-process-down one, --fresh +
# ownership transfer only if the owner worktree is genuinely gone.

owner_map_path() { printf '%s/sessions/%s/thread-%s.owner' "$STATE_DIR" "$1" "$2"; }

read_owner() {
  local f
  f=$(owner_map_path "$1" "$2")
  [ -f "$f" ] || return 1
  head -1 "$f"
}

# Record campaign ownership. Idempotent; rewrites only when the worktree
# changed (ownership transfer after a dead-owner --fresh respawn).
record_owner() {
  local oracle=$1 key=$2 wt=$3
  { [ -z "$key" ] || [ -z "$wt" ]; } && return 0
  local f
  f=$(owner_map_path "$oracle" "$key")
  mkdir -p "$(dirname "$f")"
  if [ "$(cat "$f" 2>/dev/null)" != "$wt" ]; then
    printf '%s\n' "$wt" >"$f"
    log "[$oracle] owner[thread-$key] = $wt"
  fi
}

# Derive a session-id (UUID) from a worktree path: the newest JSONL basename
# under the encoded claude project dir. ASSUMPTION (thread #151 refinement
# #2): one claude session per worktree — true for the single-purpose dispatch
# worktrees maw creates. If a human ran several claude sessions in the same
# worktree this picks the most recent; a future debugger chasing a wrong
# --resume target should start here.
derive_session_id() {
  local wt=$1 proj jsonl
  [ -z "$wt" ] && return 1
  proj="$CLAUDE_PROJECTS/$(encode_cwd "$wt")"
  [ -d "$proj" ] || return 1
  jsonl=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1)
  [ -z "$jsonl" ] && return 1
  basename "$jsonl" .jsonl
}

# Scan an envelope for parent_thread + parent_session; if both are present,
# record the campaign owner under parent_oracle. Called for every envelope in
# scan_inbox — cheap, idempotent, and learns ownership from the OUTBOUND
# dispatch envelope before any reply exists.
record_owner_from_envelope() {
  local file=$1 pt po ps
  pt=$(grep '^parent_thread:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  ps=$(grep '^parent_session:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  { [ -z "$pt" ] || [ -z "$ps" ]; } && return 0
  po=$(grep '^parent_oracle:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  [ -z "$po" ] && return 0
  record_owner "$po" "$pt" "$ps"
}

# Owner liveness state for reply routing (thread #151 §4). Reuses
# claude_alive_at's active/idle logic — "busy" = JSONL written within
# CLAUDE_STUCK_TIMEOUT, i.e. mid-turn; "idle" = process up but JSONL quiet
# past that window, i.e. waiting at its prompt.
#   busy       process up at owner_wt AND JSONL active  → defer
#   idle       process up at owner_wt BUT JSONL quiet   → send-keys deliver
#   resumable  no process at owner_wt, worktree present → --resume
#   gone       worktree dir missing                     → --fresh + transfer
owner_state() {
  local wt=$1
  { [ -z "$wt" ] || [ ! -d "$wt" ]; } && { echo gone; return; }
  if [ -n "$(claude_pids_at "$wt")" ]; then
    if claude_alive_at "$wt"; then echo busy; else echo idle; fi
  else
    echo resumable
  fi
}

# Resolve the tmux pane whose current path is the owner worktree.
tmux_pane_for_wt() {
  local wt=$1
  [ -z "$wt" ] && return 1
  tmux list-panes -a -F '#{pane_id} #{pane_current_path}' 2>/dev/null \
    | awk -v wt="$wt" '$2==wt {print $1; exit}'
}

# Deliver a prompt into a live owner session via tmux send-keys (§4 idle case).
# §5 pick (a): owner_state's JSONL-idle gate already excluded the dangerous
# mid-turn collision. The residual risk is a human who typed-but-did-not-submit
# — their input buffer gets the appended text, which is visible and
# recoverable (they see it and edit the line), not data loss.
deliver_to_owner() {
  local wt=$1 prompt=$2 pane
  pane=$(tmux_pane_for_wt "$wt") || return 1
  [ -z "$pane" ] && return 1
  tmux send-keys -t "$pane" -l -- "$prompt" 2>/dev/null || return 1
  sleep 0.4
  tmux send-keys -t "$pane" Enter 2>/dev/null || return 1
  return 0
}

# True (0) iff another envelope for the same campaign wake key is currently
# in flight — fired / verified / delivered_to_owner (NOT deferred). Serializes
# an owned campaign's replies through the single owner session: one reply is
# routed at a time, the rest defer. Without this, two replies arriving in one
# scan would both see the owner `resumable` and each --resume the same
# session-id — two claude processes on one JSONL. `deferred` is deliberately
# excluded so two queued siblings don't each treat the other as in-flight
# (mutual-defer deadlock); sequential scan order then elects the winner.
campaign_inflight() {
  local oracle=$1 key=$2 self_sf=$3 other st
  [ -z "$key" ] && return 1
  for other in "$STATE_DIR"/state/"$oracle"/*.state; do
    [ -f "$other" ] || continue
    [ "$other" = "$self_sf" ] && continue
    grep -q "^wake_key=$key$" "$other" 2>/dev/null || continue
    st=$(grep '^status=' "$other" | tail -1 | cut -d= -f2)
    case "$st" in
      fired|verified|delivered_to_owner) return 0 ;;
    esac
  done
  return 1
}

# Path 1 helpers — find a prior wt_path that handled a given wake key for an
# oracle. Reads the most-recent state file matching that (oracle, wake_key)
# tuple (whether `completed` or terminal-success) — its wt_path is the
# candidate for --resume reuse.
find_prior_wt_for_key() {
  local oracle=$1 key=$2
  [ -z "$key" ] && return 1
  local state_dir="$STATE_DIR/state/$oracle"
  [ ! -d "$state_dir" ] && return 1
  # Newest state file first; pick the first one whose wake_key + wt_path match.
  local latest
  latest=$(ls -t "$state_dir"/*.state 2>/dev/null | while read -r f; do
    grep -q "^wake_key=$key$" "$f" 2>/dev/null && echo "$f"
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

# ─── Fan-out dedup fallback (§11k + §153) ──────────────────────────────────
#
# This is the no-owner-record fallback behind §151 owner routing — see
# maybe_fire_or_defer §2. Used for EVERY oracle (§153): an orchestrator whose
# fan-out replies share a parent_thread, AND a worker getting a 2nd dispatch
# for a campaign whose first dispatch fired but could not record an owner
# (fire_wake parsed no worktree path, or a fire_failed left a non-terminal
# state). Either way, dedup keeps a busy campaign to ONE session.
#
# True (0) iff a NEW envelope for wake key `key` must DEFER rather than fire,
# because the campaign already has work in progress. "Busy" means either:
#   (a) another non-terminal state file (fired|verified|deferred) shares the
#       wake_key — a wake for this campaign is already mid-flight or queued; OR
#   (b) a session-id is mapped for the key AND its worktree still has an
#       actively-working claude (claude_alive_at).
# When neither holds the campaign is idle: firing now produces exactly ONE
# session — a fresh spawn (no prior) or a --resume into the idle worktree.
parent_session_busy() {
  local oracle=$1 key=$2 self_sf=$3
  [ -z "$key" ] && return 1

  local other st
  for other in "$STATE_DIR"/state/"$oracle"/*.state; do
    [ -f "$other" ] || continue
    [ "$other" = "$self_sf" ] && continue
    grep -q "^wake_key=$key$" "$other" 2>/dev/null || continue
    st=$(grep '^status=' "$other" | tail -1 | cut -d= -f2)
    case "$st" in
      fired|verified|deferred) return 0 ;;
    esac
  done

  local sid_file="$STATE_DIR/sessions/$oracle/thread-$key.session-id"
  if [ -f "$sid_file" ]; then
    local prior_wt
    prior_wt=$(find_prior_wt_for_key "$oracle" "$key")
    [ -n "$prior_wt" ] && [ -d "$prior_wt" ] && claude_alive_at "$prior_wt" && return 0
  fi
  return 1
}

# For a DEFERRED envelope: true (0) iff it should fire now. The campaign must
# be idle (no fired/verified sibling, no live prior claude) AND this envelope
# must be the highest-priority deferred one for the key — oldest deferred_since,
# filename tie-break. Exactly one deferred envelope wins per idle window; once
# it fires (status=fired) the rest see a fired sibling and keep waiting. This
# winner-election is what stops two deferred siblings from each treating the
# other as "busy" forever (mutual-defer deadlock).
deferred_ready_to_fire() {
  local oracle=$1 key=$2 self_sf=$3 self_since=$4
  [ -z "$key" ] && return 1
  local other st osince
  for other in "$STATE_DIR"/state/"$oracle"/*.state; do
    [ -f "$other" ] || continue
    [ "$other" = "$self_sf" ] && continue
    grep -q "^wake_key=$key$" "$other" 2>/dev/null || continue
    st=$(grep '^status=' "$other" | tail -1 | cut -d= -f2)
    case "$st" in
      fired|verified) return 1 ;;   # a live wake already owns the key
      deferred)
        osince=$(grep '^deferred_since=' "$other" | tail -1 | cut -d= -f2)
        osince=${osince:-0}
        if [ "$osince" -lt "$self_since" ] 2>/dev/null; then
          return 1                  # older deferred sibling outranks us
        elif [ "$osince" -eq "$self_since" ] 2>/dev/null \
             && [ "$(basename "$other")" \< "$(basename "$self_sf")" ]; then
          return 1                  # same age — lexically-first filename wins
        fi
        ;;
    esac
  done
  # No blocking sibling — last gate: any prior claude must be idle/dead.
  local sid_file="$STATE_DIR/sessions/$oracle/thread-$key.session-id"
  if [ -f "$sid_file" ]; then
    local prior_wt
    prior_wt=$(find_prior_wt_for_key "$oracle" "$key")
    [ -n "$prior_wt" ] && [ -d "$prior_wt" ] && claude_alive_at "$prior_wt" && return 1
  fi
  return 0
}

# ─── State transitions ─────────────────────────────────────────────────────

fire_wake() {
  local oracle=$1 file=$2 fname=$3
  local thread_id wkey wake_ts wt_suffix sf wake_out wt_path
  local sid_file prior_sid prior_wt resume_sid wt_arg

  thread_id=$(grep '^thread:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  # Wake key — parent_thread for any fan-out sub-task envelope, else thread.
  # Drives the §11f session map + Path 1 worktree reuse so a campaign's
  # sub-threads converge on one session per oracle (§11k campaign reuse).
  wkey=$(wake_key "$file" "$thread_id")
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
    cancel_prior_wt=$(find_prior_wt_for_key "$oracle" "$wkey")
    if [ -n "$cancel_prior_wt" ] && [ -d "$cancel_prior_wt" ] \
       && [ -n "$(claude_pids_at "$cancel_prior_wt")" ]; then
      log "[$oracle] CANCEL PRE-EMPT — terminating claude(s) at $cancel_prior_wt for thread $thread_id"
      preempt_claude_at "$cancel_prior_wt"
    fi
  fi

  # Path 1 — worktree reuse via maw --resume. If we already have a
  # session-id mapped for this (oracle, wake-key) AND no claude is currently
  # alive in the worktree that birthed it, resume that session in the SAME
  # worktree instead of spawning a fresh one. Drives worktree count toward
  # (oracle × campaign) pairs rather than total wakes. Falls back to --fresh
  # silently if any precondition is missing.
  #
  # Skipped for cancel envelopes (handled above): cancel handler runs on
  # a fresh wake; prior session was just killed so resume would fail
  # anyway and the cancel doesn't need that context.
  if [ -n "$wkey" ] && ! is_cancel_envelope "$file"; then
    sid_file="$STATE_DIR/sessions/$oracle/thread-$wkey.session-id"
    if [ -f "$sid_file" ]; then
      prior_sid=$(cat "$sid_file")
      prior_wt=$(find_prior_wt_for_key "$oracle" "$wkey")
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
    "wake_key=$wkey" \
    "wt_suffix=$wt_suffix" \
    "status=fired"
  [ -n "${resume_sid:-}" ] && set_state_field "$sf" resume_sid "$resume_sid"

  log "[$oracle] $fname → fire (thread=$thread_id, suffix=$wt_suffix${resume_sid:+, RESUME sid=$resume_sid})"

  # Build prompt with FULL envelope path embedded. Without the path, fresh
  # subagents respond to `inbox: <fname>` by running `find / -name <fname>`,
  # which on macOS aliases to bfs and gets stuck on /System/Volumes/Data
  # (APFS firmlinks) — each scan holds ~30k FDs and never returns. Observed
  # 2026-05-16: 6 such bfs orphans consumed 285k FDs systemwide, blocking
  # github.com access for brew-ops-bot's `maw wake`. Keeping the literal
  # `inbox: $fname` substring preserves T1 verification (jsonl_has_prompt,
  # line ~143) which greps for exactly that marker.
  local envelope_path="$INBOX_BASE/for-$oracle/$fname"
  local task_prompt="inbox: $fname (envelope path: $envelope_path — read this file directly with the Read tool; do not use \`find\`)"

  # Capture maw wake output to extract the resolved worktree path.
  if [ -n "${resume_sid:-}" ]; then
    wake_out=$($MAW_BIN wake "$oracle" --resume "$resume_sid" --wt "$wt_suffix" --no-attach \
      --task "$task_prompt" 2>&1) || {
      set_state_field "$sf" status fire_failed
      set_state_field "$sf" failed_at "$(date +%s)"
      alert "[$oracle] maw wake --resume exit nonzero for $fname: $(printf '%s' "$wake_out" | tail -3 | tr '\n' ' ')"
      return 1
    }
  else
    wake_out=$($MAW_BIN wake "$oracle" --fresh --wt "$wt_suffix" --no-attach \
      --task "$task_prompt" 2>&1) || {
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

  # Sticky ownership (thread #151): the worktree this wake used becomes the
  # campaign owner. For a dead-owner --fresh respawn this is the ownership
  # *transfer*; for a campaign with no prior owner it establishes one.
  [ -n "$wt_path" ] && [ -n "$wkey" ] && ! is_cancel_envelope "$file" \
    && record_owner "$oracle" "$wkey" "$wt_path"
}

verify_delivery() {
  local sf=$1
  read_state "$sf" || return 0
  local now age proj_dir jsonl sid sids_dir key
  now=$(date +%s)
  age=$((now - fired_at))

  if [ -n "${wt_path:-}" ]; then
    proj_dir=$CLAUDE_PROJECTS/$(encode_cwd "$wt_path")
    if [ -d "$proj_dir" ]; then
      jsonl=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1)
      if [ -n "$jsonl" ] && jsonl_has_prompt "$jsonl" "$fname"; then
        sid=$(basename "$jsonl" .jsonl)
        # Capture the session under the WAKE KEY (parent_thread for any
        # fan-out sub-task, else thread) so later same-campaign sub-threads
        # resume this session instead of spawning a sibling (§11f/§11k).
        key=${wake_key:-$thread_id}
        if [ -n "$key" ]; then
          sids_dir=$STATE_DIR/sessions/$oracle
          mkdir -p "$sids_dir"
          printf '%s\n' "$sid" >"$sids_dir/thread-$key.session-id"
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
# Endpoint is `$ORACLE_API/thread/<id>` → `{"thread":{"status":...},...}`.
# (Was `forum/thread/<id>` — a 404 that silently returned empty, so
# safe_to_retire saw every thread as not-closed and the auto-retire never
# fired. That broken endpoint is why the worktree purge had to be manual.)
thread_status() {
  local id=$1
  [ -z "$id" ] && { echo ""; return; }
  curl -sf -m 3 "$ORACLE_API/thread/$id" 2>/dev/null \
    | jq -r '.thread.status // empty' 2>/dev/null
}

# True iff any other NON-TERMINAL state file (not $sf) references the same
# wt_path. Only a non-terminal sibling — `fired` / `verified` / `deferred` /
# `delivered_to_owner` — still has live work in the worktree and so must
# block its retire. A terminal sibling (`completed` / `failed_no_prompt` /
# `failed_stuck` / `fire_failed`) is done with the worktree.
#
# The status filter is load-bearing (thread #172). The §11f/§11k
# campaign-session-reuse pattern parks EVERY sub-thread envelope of a
# campaign on the one shared `wt_path`. Once such a campaign closes, all its
# envelopes are terminal — and the pre-filter check (any state file at all)
# made each envelope cite the others as a reason to skip: a mutual-blocking
# deadlock in which the worktree could never retire. 7 of 10 mb-next
# worktrees leaked exactly this way (thread #172 audit). Terminal siblings
# no longer count, so the campaign's spawning (non-owner-routed) envelope
# now retires the shared worktree.
other_state_references_wt() {
  local sf=$1 wt=$2 st
  [ -z "$wt" ] && return 1
  for other in "$STATE_DIR"/state/*/*.state; do
    [ -f "$other" ] || continue
    [ "$other" = "$sf" ] && continue
    grep -q "^wt_path=$wt$" "$other" || continue
    st=$(grep '^status=' "$other" 2>/dev/null | tail -1 | cut -d= -f2)
    case "$st" in
      fired|verified|deferred|delivered_to_owner) return 0 ;;
    esac
  done
  return 1
}

# Remove the two untracked files maw injects into every worktree: the
# `.agent` symlink (memory mount) and a stray macOS `.DS_Store`. `git worktree
# remove` refuses a worktree with ANY untracked file, so without this every
# retire fails on the `.agent` symlink alone (Bug B, thread #139). Removing a
# symlink never touches its target — the central `mb_agent_oracle_memory`
# repo is untouched (P-001-safe) — and the worktree dir is being torn down
# anyway. `.agent` is removed ONLY when it is a symlink; a real `.agent`
# directory is left alone.
strip_worktree_noise() {
  local wt=$1
  [ -L "$wt/.agent" ] && rm -f "$wt/.agent"
  [ -f "$wt/.DS_Store" ] && rm -f "$wt/.DS_Store"
  return 0
}

# Safety gates for retiring a worktree. Returns reason string on first
# failure (caller checks $? = 0 means safe). Empty string output means OK.
safe_to_retire() {
  local sf=$1
  # `local route` so a stale value from a prior envelope's `source` cannot
  # leak in — read_state re-sources, leaving it empty when the file omits it.
  local route=""
  read_state "$sf" || { echo "state-unreadable"; return 1; }

  # §151 — never retire a worktree the watcher did not spawn. An owner-routed
  # reply (send-keys or --resume into the dispatcher's own session) records
  # the owner's worktree as wt_path; that worktree's lifecycle belongs to
  # whatever spawned it, not to this reply envelope.
  case "${route:-}" in
    owner_send_keys|owner_resume) echo "owner-routed-foreign-wt"; return 1 ;;
  esac

  [ -z "${wt_path:-}" ] && { echo "no-wt-path"; return 1; }
  [ ! -d "$wt_path" ] && { echo "wt-already-gone"; return 1; }

  local ts
  ts=$(thread_status "${thread_id:-}")
  [ "$ts" != "closed" ] && { echo "thread-${thread_id:-?}-not-closed-($ts)"; return 1; }

  # git: clean working tree + all commits pushed. The maw-injected `.agent`
  # symlink and a stray `.DS_Store` are not real work — strip_worktree_noise
  # clears them at retire time — so they don't count as dirt here (Bug B).
  local dirty
  dirty=$(git -C "$wt_path" status --short 2>/dev/null \
    | grep -vE '^\?\? \.(agent|DS_Store)/?$' | head -1)
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
  #
  # The main repo is the worktree path minus its `.wt-<N>-<suffix>` tail.
  # maw creates worktrees as SIBLINGS of the main checkout
  # (`<repo>.wt-42-…` next to `<repo>`), not as children — so `git worktree
  # remove` must run with `-C <main repo>`. `-C "$wt_path/.."` (used before
  # this fix) resolved to the *parent directory that holds both*, which is
  # not a git repo at all, so the remove returned nonzero on every retire
  # and NO worktree was ever reclaimed. `-C "$wt_path"` is equally wrong: a
  # linked worktree cannot remove itself. Same derivation as discover_repos.
  local repo_path branch
  repo_path=${wt_path%.wt-*}
  branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null)

  # Best-effort kill the tmux window for this wake (non-fatal if gone).
  $MAW_BIN ls 2>/dev/null | grep -q "${wt_suffix:-__none__}" && {
    $MAW_BIN kill "*:*${wt_suffix}*" 2>/dev/null || true
  }

  # git worktree remove (refuses on dirty by default — safe). Strip the
  # maw-injected `.agent` symlink + `.DS_Store` first so the otherwise-clean
  # worktree isn't rejected for those alone (Bug B).
  strip_worktree_noise "$wt_path"
  if git -C "$repo_path" worktree remove "$wt_path" 2>>"$LOG_FILE"; then
    log "[$oracle] $fname RETIRED worktree $wt_path"
    # Best-effort branch delete (only succeeds if merged or no unique commits)
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] && \
      git -C "$repo_path" branch -d "$branch" 2>/dev/null && \
      log "[$oracle] retired branch $branch"
    set_state_field "$sf" retired_at "$(date +%s)"
    # Drop the campaign session-id cache entry now the worktree is gone (§11f).
    evict_session_id "$oracle" "${wake_key:-$thread_id}" "$sf"
  else
    log "[$oracle] $fname retire FAILED (git worktree remove returned nonzero — keeping)"
  fi
}

# Drop the session-id cache file for a wake key once its campaign retires
# (§11f eviction). Guarded: if another non-terminal envelope still shares the
# wake key — a sibling sub-thread of the same campaign is mid-flight — the
# session is still needed for its --resume, so keep it.
evict_session_id() {
  local oracle=$1 key=$2 self_sf=$3
  [ -z "$key" ] && return 0
  local other st
  for other in "$STATE_DIR"/state/"$oracle"/*.state; do
    [ -f "$other" ] || continue
    [ "$other" = "$self_sf" ] && continue
    grep -q "^wake_key=$key$" "$other" 2>/dev/null || continue
    st=$(grep '^status=' "$other" | tail -1 | cut -d= -f2)
    case "$st" in
      fired|verified|deferred) return 0 ;;  # campaign sibling still live
    esac
  done
  local sid_file="$STATE_DIR/sessions/$oracle/thread-$key.session-id"
  if [ -f "$sid_file" ]; then
    rm -f "$sid_file"
    log "[$oracle] evicted session-id thread-$key (campaign retired)"
  fi
}

# ─── Path 2b — periodic campaign GC sweep ─────────────────────────────────
#
# maybe_retire_worktree only fires the instant an envelope reaches
# `completed`. Three things slip past it, so a periodic sweep mops up:
#
#   (1) An envelope that reached a terminal state while its thread was still
#       open had its retire SKIPPED (thread-not-closed gate) and the thread
#       closing later triggers nothing. gc_retire_terminal re-runs the retire
#       gate on every terminal-but-not-retired envelope. Terminal covers both
#       `completed` AND the terminal-failure states `failed_no_prompt` /
#       `failed_stuck`: a failed envelope still holds a state file referencing
#       its worktree, so gc_prune_orphan_worktrees skips it too — without this
#       its worktree leaks forever (#164: wt-9 failed_no_prompt, wt-50
#       failed_stuck). The retire gate (safe_to_retire) is the SAME for all
#       three — thread closed, tree clean, claude dead, not owner-routed.
#   (2) session-id cache files accumulate. Retire-driven eviction
#       (evict_session_id) handles closed campaigns; gc_evict_stale_sessions
#       is the 30-day TTL backstop for campaigns whose thread never closed.
#   (3) Worktrees orphaned by crashes / manual tmux kills sit on disk forever
#       — no tmux window, no live claude, not referenced by any envelope
#       state. gc_prune_orphan_worktrees removes them under the same
#       git-clean + no-unpushed gate as the #116 per-envelope retire. This is
#       the manual 47→5 worktree purge made routine.
#
# Not in scope: pruning `.agent.bak-*` directories. Those can hold pre-symlink
# `.agent/` memory content; deleting them risks a P-001 ("Nothing is Deleted")
# violation and AGENTS.md §3a explicitly says to leave them. Surfacing this
# rather than auto-deleting — see the thread-139 reply envelope.

# Distinct product-repo roots inferred from recorded wt_paths. A worktree
# path is `<repo>.wt-<N>-<suffix>`, so stripping `.wt-*` yields the repo.
# Multiple repos appear because different oracles wake in different repos
# (orchestrator/brew-ops → arra-oracle-v3, next-* → mb-next-payment-gateway…).
discover_repos() {
  local sf wt
  for sf in "$STATE_DIR"/state/*/*.state; do
    [ -f "$sf" ] || continue
    wt=$(grep '^wt_path=' "$sf" 2>/dev/null | tail -1 | cut -d= -f2-)
    case "$wt" in *.wt-*) echo "${wt%.wt-*}" ;; esac
  done | sort -u
}

# (1) Re-run the retire gate on terminal-but-not-retired envelopes. A retire
# SKIPPED earlier for `thread-not-closed` succeeds here once the thread closes.
# Terminal = `completed` plus the terminal-failure states (#164): a
# `failed_no_prompt` / `failed_stuck` envelope still pins its worktree via a
# state file, so without this it never gets reaped. safe_to_retire (called by
# maybe_retire_worktree) is the only gate — identical for success and failure,
# so failure envelopes are NOT retired any more eagerly than completed ones.
gc_retire_terminal() {
  local sf
  for sf in "$STATE_DIR"/state/*/*.state; do
    [ -f "$sf" ] || continue
    unset status retired_at
    # shellcheck disable=SC1090
    source "$sf"
    case "${status:-}" in
      completed|failed_no_prompt|failed_stuck) ;;
      *) continue ;;
    esac
    [ -n "${retired_at:-}" ] && continue
    maybe_retire_worktree "$sf"
  done
}

# (2) Drop session-id cache files idle longer than the TTL.
gc_evict_stale_sessions() {
  local now sid_file mtime age_days
  now=$(date +%s)
  for sid_file in "$STATE_DIR"/sessions/*/thread-*.session-id; do
    [ -f "$sid_file" ] || continue
    mtime=$(stat -f %m "$sid_file" 2>/dev/null) || continue
    age_days=$(( (now - mtime) / 86400 ))
    if [ "$age_days" -ge "$SESSION_TTL_DAYS" ]; then
      rm -f "$sid_file"
      log "gc: evicted stale session-id ${sid_file#"$STATE_DIR/sessions/"} (idle ${age_days}d ≥ ${SESSION_TTL_DAYS}d TTL)"
    fi
  done
}

# True iff any envelope state file references a worktree with the same
# basename as $wt. Basename match (not full path) is deliberate: git's
# `worktree list` and the maw-captured wt_path can differ by a path prefix
# (/tmp vs /private/tmp symlink resolution, trailing slash), and a missed
# match here would prune a worktree an active envelope still owns. Worktree
# basenames carry a unique timestamp suffix, so basename collisions can't
# happen; erring toward "referenced" (keep) is the safe direction.
any_state_references_wt() {
  local wt=$1 bn other
  bn=$(basename "$wt")
  for other in "$STATE_DIR"/state/*/*.state; do
    [ -f "$other" ] || continue
    grep -q "^wt_path=.*/$bn\$" "$other" 2>/dev/null && return 0
  done
  return 1
}

# (3a) Remove one worktree iff it is a genuine orphan: no tmux window for its
# suffix, no live claude, git-clean + no-unpushed, not referenced by any
# envelope state. Same safety floor as safe_to_retire (#116 gate). Skips with
# a logged reason on any failure — never forces.
gc_try_prune_worktree() {
  local repo=$1 wt=$2 maw_windows=$3
  local suffix dirty unpushed branch
  suffix=$(basename "$wt" | sed 's/^[^.]*\.wt-[0-9]*-//')

  # Referenced by an envelope state file → that envelope owns the retire.
  any_state_references_wt "$wt" && return 0
  # tmux window still open for this suffix → in use.
  [ -n "$suffix" ] && printf '%s' "$maw_windows" | grep -q "$suffix" && return 0
  claude_alive_at "$wt" && return 0
  dirty=$(git -C "$wt" status --short 2>/dev/null \
    | grep -vE '^\?\? \.(agent|DS_Store)/?$' | head -1)
  [ -n "$dirty" ] && { log "gc: keep orphan-candidate $wt (dirty)"; return 0; }
  unpushed=$(git -C "$wt" log '@{u}..' --oneline 2>/dev/null | head -1)
  [ -n "$unpushed" ] && { log "gc: keep orphan-candidate $wt (unpushed commits)"; return 0; }

  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  strip_worktree_noise "$wt"
  if git -C "$repo" worktree remove "$wt" 2>>"$LOG_FILE"; then
    log "gc: pruned orphan worktree $wt"
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] && \
      git -C "$repo" branch -d "$branch" 2>/dev/null && \
      log "gc: pruned merged branch $branch"
  else
    log "gc: orphan-prune FAILED for $wt (git worktree remove nonzero — keeping)"
  fi
}

# (3) Sweep every discovered repo for orphan worktrees.
gc_prune_orphan_worktrees() {
  local repo wt maw_windows
  maw_windows=$($MAW_BIN ls 2>/dev/null)
  while read -r repo; do
    [ -z "$repo" ] && continue
    [ -d "$repo/.git" ] || [ -e "$repo/.git" ] || continue
    git -C "$repo" worktree list --porcelain 2>/dev/null \
      | sed -n 's/^worktree //p' | while read -r wt; do
      [ "$wt" = "$repo" ] && continue          # never the main worktree
      case "$wt" in *.wt-*) ;; *) continue ;; esac
      [ -d "$wt" ] || continue
      gc_try_prune_worktree "$repo" "$wt" "$maw_windows"
    done
  done < <(discover_repos)
}

# Periodic GC entry point — called from run_loop on the INBOX_GC_INTERVAL
# cadence. Gated by INBOX_AUTO_CLEAN like the per-envelope retire.
gc_sweep() {
  [ "$INBOX_AUTO_CLEAN" = "1" ] || return 0
  log "gc-sweep start"
  gc_retire_terminal
  gc_evict_stale_sessions
  gc_prune_orphan_worktrees
  log "gc-sweep done"
  return 0
}

# ─── Fire-or-defer dispatch (§11k fan-out dedup + §151 owner routing) ──────

# Route a reply into its campaign owner (thread #151 §4). Two sub-cases:
#  idle      — owner process up but JSONL quiet: tmux send-keys the prompt
#              into its live window (no new worktree, no --fresh).
#  resumable — owner process down, worktree present: maw wake --resume the
#              owner's session-id in its own worktree.
# Both record route=owner_* so the retire machinery leaves the foreign
# worktree alone (safe_to_retire gate). owner_state must have returned
# idle|resumable before this is called; a resumable owner with no derivable
# session-id falls back to a plain --fresh fire_wake.
fire_to_owner() {
  local oracle=$1 file=$2 fname=$3 sf=$4 wkey=$5 owner_wt=$6
  local thread_id envelope_path task_prompt wake_ts
  local resume_sid wt_suffix wake_out

  thread_id=$(grep '^thread:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  envelope_path="$INBOX_BASE/for-$oracle/$fname"
  task_prompt="inbox: $fname (envelope path: $envelope_path — read this file directly with the Read tool; do not use \`find\`)"
  wake_ts=$(date +%s)

  if [ "$(owner_state "$owner_wt")" = "idle" ]; then
    # Write state BEFORE delivering so a racing scan can't double-fire.
    write_state "$sf" \
      "fired_at=$wake_ts" "oracle=$oracle" "fname=$fname" \
      "thread_id=$thread_id" "wake_key=$wkey" "wt_path=$owner_wt" \
      "route=owner_send_keys" "status=delivered_to_owner"
    if deliver_to_owner "$owner_wt" "$task_prompt"; then
      # thread #151 refinement #1 — log every send-keys into a session the
      # watcher did not spawn, so a human-buffer collision is auditable.
      log "[$oracle] $fname → delivered_to_owner via send-keys into $owner_wt (watcher did not spawn this session)"
    else
      set_state_field "$sf" status fire_failed
      set_state_field "$sf" failed_at "$(date +%s)"
      alert "[$oracle] $fname send-keys delivery to owner $owner_wt FAILED (no tmux pane for that worktree)"
    fi
    return 0
  fi

  # resumable — owner process is down; --resume its session in its worktree.
  resume_sid=$(derive_session_id "$owner_wt") || resume_sid=""
  if [ -z "$resume_sid" ]; then
    log "[$oracle] $fname → owner $owner_wt resumable but no session-id derivable; --fresh fallback"
    fire_wake "$oracle" "$file" "$fname"
    return 0
  fi
  wt_suffix=$(basename "$owner_wt" | sed 's/^[^.]*\.wt-[0-9]*-//')
  write_state "$sf" \
    "fired_at=$wake_ts" "oracle=$oracle" "fname=$fname" \
    "thread_id=$thread_id" "wake_key=$wkey" "wt_suffix=$wt_suffix" \
    "wt_path=$owner_wt" "route=owner_resume" "resume_sid=$resume_sid" \
    "status=fired"
  log "[$oracle] $fname → fire (RESUME owner sid=$resume_sid, wt=$owner_wt)"
  wake_out=$($MAW_BIN wake "$oracle" --resume "$resume_sid" --wt "$wt_suffix" --no-attach \
    --task "$task_prompt" 2>&1) || {
    set_state_field "$sf" status fire_failed
    set_state_field "$sf" failed_at "$(date +%s)"
    alert "[$oracle] maw wake --resume (owner) exit nonzero for $fname: $(printf '%s' "$wake_out" | tail -3 | tr '\n' ' ')"
    return 1
  }
  printf '%s\n' "$wake_out" >>"$LOG_FILE"
  return 0
}

# Entry point for a NEW envelope. Decision order:
#  1. §151 owner routing — if the campaign has a recorded owner, route the
#     reply/dispatch back to that exact session (busy=defer, idle=send-keys,
#     resumable=--resume, gone=--fresh+transfer). Oracle-agnostic, so a 2nd
#     dispatch to a busy worker is already serialized onto its session.
#  2. §11k/§153 fan-out dedup fallback — reached only when no owner record
#     exists (a pre-#151 dispatcher that did not stamp parent_session, or a
#     worker whose first dispatch fired but recorded no worktree path).
#     Applies to EVERY oracle so a busy worker never gets a sibling spawned
#     (the wt-43/wt-46 incident, thread #151/#153). When it un-defers,
#     fire_wake Path 1 --resumes the campaign session.
#  3. plain fire_wake.
# Cancel envelopes (priority-1) skip owner routing and always fire fresh.
maybe_fire_or_defer() {
  local oracle=$1 file=$2 fname=$3 sf=$4
  local thread_id wkey owner_wt

  thread_id=$(grep '^thread:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
  wkey=$(wake_key "$file" "$thread_id")

  # ── 1. Sticky owner routing (thread #151) ───────────────────────────────
  if [ -n "$wkey" ] && ! is_cancel_envelope "$file"; then
    owner_wt=$(read_owner "$oracle" "$wkey" 2>/dev/null) || owner_wt=""
    if [ -n "$owner_wt" ]; then
      # Serialize: if a sibling reply for this campaign is already in flight,
      # defer so the owner processes replies one at a time.
      if campaign_inflight "$oracle" "$wkey" "$sf"; then
        write_state "$sf" \
          "oracle=$oracle" "fname=$fname" "thread_id=$thread_id" \
          "wake_key=$wkey" "deferred_since=$(date +%s)" \
          "defer_reason=owner-busy" "status=deferred"
        log "[$oracle] $fname → DEFER (campaign $wkey reply already in flight; serializing through owner)"
        return 0
      fi
      case "$(owner_state "$owner_wt")" in
        busy)
          write_state "$sf" \
            "oracle=$oracle" "fname=$fname" "thread_id=$thread_id" \
            "wake_key=$wkey" "deferred_since=$(date +%s)" \
            "defer_reason=owner-busy" "status=deferred"
          log "[$oracle] $fname → DEFER (owner $owner_wt busy mid-turn; will deliver when idle)"
          return 0 ;;
        idle|resumable)
          fire_to_owner "$oracle" "$file" "$fname" "$sf" "$wkey" "$owner_wt"
          return 0 ;;
        gone)
          log "[$oracle] $fname → owner $owner_wt gone; --fresh respawn + ownership transfer" ;;
      esac
    fi
  fi

  # ── 2. Fan-out dedup fallback (§11k + §153) — no owner-record case ───────
  # Symmetric mirror of §1: when a campaign has work in flight but NO owner
  # record (the first dispatch's fire_wake parsed no worktree path, or a
  # fire_failed left a non-terminal state), defer behind the in-flight sibling
  # instead of --fresh-spawning. NOT gated to the orchestrator (§153): a busy
  # worker getting a 2nd same-campaign dispatch must serialize onto its
  # existing session, never spawn a sibling (the wt-43/wt-46 incident). When
  # it un-defers, fire_wake Path 1 --resumes the campaign session.
  if ! is_cancel_envelope "$file"; then
    if [ -n "$wkey" ] && parent_session_busy "$oracle" "$wkey" "$sf"; then
      write_state "$sf" \
        "oracle=$oracle" \
        "fname=$fname" \
        "thread_id=$thread_id" \
        "wake_key=$wkey" \
        "deferred_since=$(date +%s)" \
        "status=deferred"
      log "[$oracle] $fname → DEFER (campaign $wkey already has a live session; queued, will --resume into it when idle)"
      return 0
    fi
  fi
  fire_wake "$oracle" "$file" "$fname"
}

# A deferred envelope re-evaluates every scan. Once the parent campaign goes
# idle this envelope (if it wins the deferred-sibling election) fires — and
# fire_wake's Path 1 --resumes the campaign's worktree, so no sibling session
# is ever spawned. If the campaign stays busy past T2 the envelope is NOT
# lost — it stays queued and an alert surfaces the backlog.
reconsider_deferred() {
  local sf=$1 file=$2
  read_state "$sf" || return 0
  local key=${wake_key:-$thread_id} now age

  if [ ! -f "$file" ]; then
    # Envelope archived out-of-band while deferred — close it out.
    set_state_field "$sf" status completed
    set_state_field "$sf" completed_at "$(date +%s)"
    log "[$oracle] $fname COMPLETED (archived while deferred)"
    return 0
  fi

  # §151 owner-busy defer — re-route the moment the owner becomes reachable.
  if [ "${defer_reason:-}" = "owner-busy" ]; then
    local owner_wt ostate
    # A sibling reply still in flight → keep queued (sequential scan order
    # over the deferred siblings elects the winner once it clears).
    if campaign_inflight "$oracle" "$key" "$sf"; then
      now=$(date +%s)
      age=$((now - ${deferred_since:-now}))
      [ "$age" -ge "$T2_PROCESSING_DEADLINE" ] && \
        alert "[$oracle] $fname DEFERRED ${age}s — campaign $key sibling still in flight past T2; still queued"
      return 0
    fi
    owner_wt=$(read_owner "$oracle" "$key" 2>/dev/null) || owner_wt=""
    ostate=gone
    [ -n "$owner_wt" ] && ostate=$(owner_state "$owner_wt")
    case "$ostate" in
      busy)
        now=$(date +%s)
        age=$((now - ${deferred_since:-now}))
        [ "$age" -ge "$T2_PROCESSING_DEADLINE" ] && \
          alert "[$oracle] $fname DEFERRED ${age}s — owner still busy past T2; still queued (not dropped)"
        return 0 ;;
      idle|resumable)
        log "[$oracle] $fname → un-defer (owner now reachable; routing to it)"
        if mkdir "$sf.lock" 2>/dev/null; then
          fire_to_owner "$oracle" "$file" "$fname" "$sf" "$key" "$owner_wt"
          rmdir "$sf.lock" 2>/dev/null
        fi
        return 0 ;;
      gone)
        log "[$oracle] $fname → un-defer (owner gone; --fresh respawn + ownership transfer)"
        if mkdir "$sf.lock" 2>/dev/null; then
          fire_wake "$oracle" "$file" "$fname"
          rmdir "$sf.lock" 2>/dev/null
        fi
        return 0 ;;
    esac
  fi

  if deferred_ready_to_fire "$oracle" "$key" "$sf" "${deferred_since:-0}"; then
    log "[$oracle] $fname → un-defer (parent campaign $key now idle; resuming into it)"
    if mkdir "$sf.lock" 2>/dev/null; then
      fire_wake "$oracle" "$file" "$fname"
      rmdir "$sf.lock" 2>/dev/null
    fi
    return 0
  fi

  now=$(date +%s)
  age=$((now - ${deferred_since:-now}))
  if [ "$age" -ge "$T2_PROCESSING_DEADLINE" ]; then
    alert "[$oracle] $fname DEFERRED ${age}s — parent campaign $key still busy past T2; still queued (not dropped)"
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

      # §151 — learn campaign ownership from any envelope carrying
      # parent_thread + parent_session (the outbound dispatch). Idempotent;
      # runs before the new/in-progress branch so ownership is recorded even
      # for envelopes already past their fire.
      record_owner_from_envelope "$file"

      sf=$(state_path "$oracle" "$fname")

      if [ ! -f "$sf" ]; then
        # Atomic claim before firing. `mkdir` is POSIX-atomic: if two scans
        # ever interleave on the same envelope (parallel watcher daemons —
        # see find_other_daemons; or a future change that runs scan_inbox
        # concurrently), only one wins the lockdir and enters fire_wake.
        # Observed 2026-05-04 11:39:56: same envelope (thread-67_reply.md)
        # fired twice in the same second; second attempt collided on
        # `git branch agents/<wt>` with "ref already exists" → fire_failed.
        # The lockdir + write_state-before-fire pair makes a duplicate-fire
        # impossible: loser sees the state file on the next scan tick.
        mkdir -p "$(dirname "$sf")"
        if mkdir "$sf.lock" 2>/dev/null; then
          maybe_fire_or_defer "$oracle" "$file" "$fname" "$sf"
          rmdir "$sf.lock" 2>/dev/null
        else
          log "[$oracle] $fname — claim contended (lock held); deferring"
        fi
      else
        # shellcheck disable=SC1090
        source "$sf"
        case "${status:-unknown}" in
          fired)              verify_delivery "$sf" ;;
          delivered_to_owner) verify_delivery "$sf" ;;  # §151 send-keys — T1 on owner JSONL
          verified)           verify_processing "$sf" "$file" ;;
          deferred)           reconsider_deferred "$sf" "$file" ;;
          completed|failed_*|fire_failed) : ;;  # terminal
          *)                  alert "[$oracle] $fname unknown status=$status" ;;
        esac
      fi
    done
  done

  # Pass 2 — iterate state files for non-terminal envelopes whose backing file
  # has been archived (moved out of the inbox root). Pass 1 misses these
  # because it only sees files currently in for-{oracle}/, so an envelope
  # archived between two scans never reaches `completed` without it.
  for state_dir in "$STATE_DIR"/state/*/; do
    [ -d "$state_dir" ] || continue
    oracle=$(basename "$state_dir")
    [ "$oracle" = "*" ] && continue

    for sf in "$state_dir"*.state; do
      [ -f "$sf" ] || continue
      # shellcheck disable=SC1090
      source "$sf"
      file="$INBOX_BASE/for-$oracle/$fname"
      case "${status:-}" in
        verified)  [ ! -f "$file" ] && verify_processing "$sf" "$file" ;;
        # A `fired` envelope archived before Pass 1's verify_delivery ran:
        # the agent resumed, processed, and archived it inside one poll
        # interval, so the T1 probe never saw the file and the state froze
        # at `fired`. Left unreconciled, campaign_inflight() counts it as a
        # perpetual in-flight sibling and dead-locks every later envelope of
        # the campaign (thread #170 — next-writer #167 DEFERRED ~2h). The
        # file being gone proves §11d archival, i.e. the agent handled it.
        fired)     [ ! -f "$file" ] && verify_processing "$sf" "$file" ;;
        # A §151 send-keys delivery whose file was archived between scans —
        # the owner already processed it; finalize to completed here.
        delivered_to_owner) [ ! -f "$file" ] && verify_processing "$sf" "$file" ;;
        # A deferred envelope whose file was archived out-of-band: Pass 1
        # never sees it (it iterates files still in for-{oracle}/), so finalize
        # it here.
        deferred)  [ ! -f "$file" ] && reconsider_deferred "$sf" "$file" ;;
      esac
    done
  done

  # Return clean — without this, the function inherits the exit code of the
  # last test inside the inner loops and the run_loop's `|| log` branch fires
  # every minute even when the scan succeeded.
  return 0
}

run_loop() {
  log "inbox-watcher start (interval=${INBOX_POLL_INTERVAL}s, T1=${T1_DELIVERY_DEADLINE}s, T2=${T2_PROCESSING_DEADLINE}s, gc=${INBOX_GC_INTERVAL}s, enabled=$INBOX_SCAN_ENABLED)"
  local last_gc=0 now
  while true; do
    if [ "$INBOX_SCAN_ENABLED" = "1" ]; then
      scan_inbox || log "scan_inbox returned nonzero (continuing)"
      now=$(date +%s)
      if [ $((now - last_gc)) -ge "$INBOX_GC_INTERVAL" ]; then
        gc_sweep || log "gc_sweep returned nonzero (continuing)"
        last_gc=$now
      fi
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
    # Dedupe: PID_FILE pid is usually already in find_other_daemons output.
    others=$(printf '%s\n' $others | awk 'NF && !seen[$0]++' | tr '\n' ' ')
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
    echo
    echo "campaign owners (§151):"
    if [ -d "$STATE_DIR/sessions" ]; then
      find "$STATE_DIR/sessions" -name 'thread-*.owner' -type f 2>/dev/null | while read -r f; do
        printf '  %s → %s\n' "${f#"$STATE_DIR/sessions/"}" "$(cat "$f")"
      done
    fi
    ;;
  scan-once)
    log "scan-once (single pass)"
    scan_inbox
    ;;
  gc-once)
    log "gc-once (single GC sweep)"
    INBOX_AUTO_CLEAN=1 gc_sweep
    ;;
  *)
    cat <<USAGE >&2
usage: $0 {loop|start|stop|status|scan-once|gc-once}
  loop / start  run the watcher daemon (foreground)
  stop          kill a running daemon by pid file
  status        show pid + per-envelope state + session-id mappings
  scan-once     single scan pass (no loop) — for tests
  gc-once       single campaign GC sweep (no loop) — for tests
env overrides: INBOX_BASE, STATE_DIR, LOG_FILE, INBOX_POLL_INTERVAL,
               T1_DELIVERY_DEADLINE, T2_PROCESSING_DEADLINE,
               INBOX_SCAN_ENABLED, INBOX_AUTO_CLEAN, INBOX_GC_INTERVAL,
               SESSION_TTL_DAYS, MAW_BIN, CLAUDE_PROJECTS
USAGE
    exit 2
    ;;
esac

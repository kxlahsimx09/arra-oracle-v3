#!/usr/bin/env bash
# team-stop-doorbell-hook.sh — Agent CLI `Stop` hook: ring the orchestrator's
# doorbell when a maw-team teammate finishes a turn.
#
# Problem it fixes: the current dispatch model (workflow-2 team-dispatch via
# team-dispatch-helper.sh) spawns teammates with NO reply envelope/thread, and an
# interactive orchestrator is NOT woken by team-inbox files — so the leader only
# learns a teammate finished by POLLING (capture-pane / armed Monitor). That poll
# is the liverun gap: a finished teammate sits idle, unnoticed, burning quota.
#
# This makes completion a PUSH: the teammate's own session, on turn-end, resolves
# the orchestrator that spawned it (its --system-prompt-file embeds the
# orchestrator worktree) and `tmux send-keys` a one-line "done" into that live
# pane — the one channel an interactive claude actually reads. This is the
# PRIMARY signal; the orchestrator's armed Monitor and the chat-watcher liveness
# classifier (pane-classify.sh) are the safety nets for the cases a Stop hook
# can't cover (process crashed/API-errored mid-turn, so no clean stop fires).
#
# Non-blocking + fail-open: ALWAYS exits 0. Unlike inbox-loop-closure-hook.sh
# (which blocks the stop to enforce envelope close-out), a notify hook must never
# wedge a session — worst case here is a missed ping, never a stuck teammate.
#
# Self-gating: engages ONLY for sessions whose claude carries a team
# --system-prompt-file under …/ψ/memory/mailbox/teams/. Every other session
# (interactive dev, a non-team oracle) is a silent no-op.
#
# Owner: brew-ops. Source of truth: this file in arra-oracle-v3/scripts/;
# deployed to runtime hook dirs by install-team-stop-doorbell-hook.sh.

set -uo pipefail
trap 'exit 0' ERR                 # fail-open: never block a session on a hook bug

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./team-doorbell-lib.sh
. "$LIB_DIR/team-doorbell-lib.sh" 2>/dev/null || exit 0

COOLDOWN=${TEAM_DOORBELL_COOLDOWN:-15}
STATE_DIR=${TEAM_DOORBELL_STATE:-$HOME/.cache/team-doorbell}
mkdir -p "$STATE_DIR" 2>/dev/null || true

allow() { exit 0; }               # the only exit: ring-or-not, the session stops

# --- session id from the Stop payload (Claude: .session_id; tolerate Codex) ---
payload=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$payload" \
  | jq -r '.session_id // .payload.session_id // .payload.id // .id // empty' 2>/dev/null || true)
[ -z "$sid" ] && sid=${CLAUDE_CODE_SESSION_ID:-${SESSION_ID:-}}

# --- find THIS session's claude process via the PPID chain → read its cmdline ---
# (ps -o ppid= avoids /proc/stat's space-bearing comm field.)
find_claude_cmdline() {
  local p=$PPID c i=0
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$i" -lt 10 ]; do
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$c" in *--system-prompt-file*) printf '%s' "$c"; return 0 ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
  return 1
}
cmd=$(find_claude_cmdline) || allow
spf=$(printf '%s' "$cmd" | grep -oE -- '--system-prompt-file [^ ]+' | awk '{print $2}')
agentid=$(printf '%s' "$cmd" | grep -oE -- '--agent-id [^ ]+' | awk '{print $2}')

# --- self-gate: only dispatched team teammates ---
doorbell_is_team_spf "$spf" || allow
owt=$(doorbell_owt_from_spf "$spf") || allow

# --- keepalive filter: don't ring on throwaway idle replies ---
cwd=$(pwd)
enc=$(printf '%s' "$cwd" | sed 's|/|-|g; s|\.|-|g')
jsonl="$HOME/.claude/projects/$enc/$sid.jsonl"
if [ -n "$sid" ] && [ -f "$jsonl" ]; then
  last_user=$(grep -E '"type":[[:space:]]*"user"' "$jsonl" 2>/dev/null | tail -1)
  doorbell_is_keepalive "$last_user" && allow
fi

# --- cooldown: dedup a multi-turn burst into one ring per window ---
last_file="$STATE_DIR/$(printf '%s' "${sid:-nosid}" | tr -c 'A-Za-z0-9_.-' _).last"
now=$(date +%s)
last=$(cat "$last_file" 2>/dev/null || echo 0); [[ "$last" =~ ^[0-9]+$ ]] || last=0
[ $(( now - last )) -lt "$COOLDOWN" ] && allow
echo "$now" > "$last_file"

# --- resolve the orchestrator's live pane (cwd == its worktree) and ring it ---
orch_pane=$(tmux list-panes -a -F '#{pane_id} #{pane_current_path}' 2>/dev/null \
  | awk -v w="$owt" '$2==w {print $1; exit}')
[ -z "$orch_pane" ] && allow

who=${agentid:-teammate}
msg="✅ teammate ${who} finished a turn — review/route it. (Stop-hook doorbell; armed Monitor + chat-watcher are the backstops)"
# Bracketed-paste-safe: literal text, settle, Enter as a separate key event.
tmux send-keys -t "$orch_pane" -l "$msg" 2>/dev/null
sleep 0.4
tmux send-keys -t "$orch_pane" Enter 2>/dev/null
exit 0

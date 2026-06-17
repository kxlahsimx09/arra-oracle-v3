#!/usr/bin/env bash
# team-doorbell-lib.sh — pure decision helpers for team-stop-doorbell-hook.sh.
#
# Kept separate + side-effect-free so the hook's branching logic is unit-tested
# (tests/cli/team-stop-doorbell-decision.test.ts) without spawning claude, tmux,
# or reading /proc. The hook does the I/O (payload, /proc walk, tmux send-keys)
# and calls these to decide whether/where to ring.

# A maw-team teammate's claude is spawned with
#   --system-prompt-file <orch-worktree>/ψ/memory/mailbox/teams/<campaign>/<role>-spawn-prompt.md
# (verified against a live teammate). That `/ψ/memory/mailbox/teams/` segment is
# the precise self-gate: a regular oracle/dev session's prompt file is elsewhere,
# so the doorbell hook no-ops for everything that isn't a dispatched teammate.
doorbell_is_team_spf() {
  case "$1" in */ψ/memory/mailbox/teams/*) return 0 ;; *) return 1 ;; esac
}

# The orchestrator worktree that spawned this teammate = the spf path up to /ψ/.
# That worktree's cwd is what the hook matches against live tmux panes to find
# the leader's pane. Returns 1 (no output) if the spf has no /ψ/ segment.
doorbell_owt_from_spf() {
  local spf="$1" owt="${1%%/ψ/*}"
  [ "$owt" = "$spf" ] && return 1
  printf '%s' "$owt"
}

# True when a teammate's most-recent user turn is an agent-teams idle/keepalive
# ping (content carries `idle_notification`). The Stop that follows such a turn is
# a throwaway "Idle." reply, NOT real completion — ringing on it would reproduce
# the keepalive spam the chat-watcher works to suppress. Same trigger-keyed signal
# classify_line uses, never the reply words.
doorbell_is_keepalive() {
  case "$1" in *idle_notification*) return 0 ;; *) return 1 ;; esac
}

# Split an --agent-id (`<role>@<campaign>`) for the doorbell message.
doorbell_agentid_role()     { printf '%s' "${1%@*}"; }
doorbell_agentid_campaign() { printf '%s' "${1##*@}"; }

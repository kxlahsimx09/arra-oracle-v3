#!/usr/bin/env bash
# orchestrator-guard-hook.sh — Claude Code `PreToolUse` hook (orchestrator scope guard)
#
# Problem it fixes: the orchestrator's charter is "I dispatch, others do the
# work" (SKILL.md §Core principles 2). In practice it occasionally crosses that
# line and edits the actual artifact itself — e.g. session wt-9 (06f8cfa6) edited
# `docs/requirements/epic-payout.md` ×3 and `src/commands/shared/wake-cmd.ts` ×1,
# work that belonged to pg-writer / next-architect / brew-ops. The orchestrator
# is launched with `--dangerously-skip-permissions`, so nothing structural stops
# it; only SKILL discipline did, and discipline alone leaks.
#
# Mechanism: registered as a `PreToolUse` hook for Edit|Write|MultiEdit in
# ~/.claude/settings.json. PreToolUse hooks still run — and can still block —
# under `--dangerously-skip-permissions`, so this is a bypass-resistant guard.
# It blocks (exit 2 + stderr) any Edit/Write/MultiEdit whose target is OUTSIDE
# the orchestrator's legitimate write zones (directed-inbox envelopes, the ψ/
# vault, the bot's known-threads cache, scratch). Code/docs/config edits are the
# owning agent's job → dispatch, don't do.
#
# Self-gating: engages ONLY when the current tmux window is the orchestrator's
# (`orchestrator-oracle`). Every other role's window (brew-ops-*, pg-writer-oracle,
# next-architect-oracle, …) and every non-tmux session is a silent no-op — they
# must keep full edit rights. This is why the hook can live in the fleet-wide
# user-level settings without breaking workers.
#
# Fail-open: any unexpected condition (no tmux, no jq, malformed input, window
# undetectable) ALLOWS the action. A guard must never wedge a session. The SKILL
# discipline + retro review remain the backstops.
#
# Scope limit: guards Edit/Write/MultiEdit only — the documented failure mode.
# It deliberately does NOT police Bash (the orchestrator legitimately shells out
# for envelope heredocs, `git mv` archiving, and `maw` calls; path-filtering
# free-form commands would false-positive constantly). The SKILL "relay, don't
# judge" rule covers what this hook cannot.
#
# Owner: brew-ops. Source of truth: this file in arra-oracle-v3/scripts/;
# deployed copy at ~/.claude/hooks/ by install-orchestrator-guard-hook.sh.

set -uo pipefail

# --- fail-open helper -------------------------------------------------------
allow() { exit 0; }

# --- read hook input (stdin JSON) -------------------------------------------
command -v jq >/dev/null 2>&1 || allow
input=$(cat 2>/dev/null) || allow
[ -n "$input" ] || allow

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || allow
case "$tool" in
  Edit | Write | MultiEdit) ;;   # mutating file tools — keep checking
  *) allow ;;                    # anything else — not our concern
esac

# --- self-gating: only the orchestrator window is guarded -------------------
# GUARD_TEST_WINDOW lets the test harness simulate a window name; unset in prod.
win="${GUARD_TEST_WINDOW:-}"
if [ -z "$win" ]; then
  if [ -n "${TMUX_PANE:-}" ]; then
    win=$(tmux display-message -t "$TMUX_PANE" -p '#{window_name}' 2>/dev/null) || win=""
  else
    win=$(tmux display-message -p '#{window_name}' 2>/dev/null) || win=""
  fi
fi
case "$win" in
  orchestrator-oracle | orchestrator | orchestrator-*) ;;  # guard is ACTIVE
  *) allow ;;                                              # any other session — no-op
esac

# --- extract target path ----------------------------------------------------
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null) || allow
[ -n "$path" ] || allow

# --- allowed write zones for the orchestrator -------------------------------
[ -n "${TMPDIR:-}" ] && case "$path" in "${TMPDIR%/}"/*) allow ;; esac
case "$path" in
  */inbox/*) allow ;;                                            # directed-inbox envelopes
  *ψ* | */ψ/* | */retrospectives/* | */learnings/* | */resonance/* | */traces/*) allow ;;  # Oracle vault
  */.cache/orchestrator-bot/*) allow ;;                          # daemon known-threads cache
  /tmp/* | /private/tmp/*) allow ;;                              # scratch
esac

# --- deny: the orchestrator is reaching into agent work ---------------------
cat >&2 <<EOF
BLOCKED by orchestrator-guard — you are the orchestrator (tmux window: ${win:-?}).
You coordinate; you do not do the work (SKILL.md §Core principles 2: "I dispatch, others do the work").

Refused $tool on: $path
That path is outside your allowed write zones:
  • */inbox/*                  (dispatch + reply envelopes)
  • ψ/ vault                   (retros, learnings, resonance, traces)
  • ~/.cache/orchestrator-bot/ (known-threads cache)
  • /tmp scratch

Editing source / docs / config / SKILLs is the OWNING AGENT's job. Do this instead:
  1. open a sub-thread for the task,
  2. write an envelope to for-<role>/ with parent_thread set (workflow-1-dispatch §Step 4),
  3. let that agent make the edit and reply.
If you are convinced this edit is genuinely coordination (not agent work), stop and escalate to the user — do not work around this guard.
EOF
exit 2

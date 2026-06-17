#!/usr/bin/env bash
# pane-classify.sh — classify a teammate's live state from cheap, captured signals.
#
# Sourced by chat-watcher.sh (real-time liveness, L2). `classify_pane_state` is a
# PURE function: it makes NO tmux/ps calls itself — the caller captures the pane
# + PID-liveness and passes them in, so the decision logic is unit-testable with
# fixtures (tests/cli/pane-classify-states.test.ts).
#
# Why this exists: the orchestrator used to infer "teammate done" from the
# ABSENCE of `esc to interrupt` — one bit that can't tell apart done-OK,
# API-errored, and crashed (the liverun idle/quota-leak + lost-API-error bugs).
# This returns exactly ONE classified state instead:
#
#   working    — claude is actively generating/retrying (esc to interrupt up)
#   menu       — a `❯ N.` TUI selection menu is waiting for input
#   api_error  — claude printed an API/usage error (529/500/overloaded/timeout/limit)
#   crashed    — the claude process is gone, or no claude TUI frame is on screen
#   idle_done  — claude TUI up at the prompt, no error → finished its turn
#   unknown    — capture was empty/ambiguous; caller must take NO destructive action
#
# Patterns are env-overridable so a claude TUI string change needs no code edit —
# set CLAUDE_*_RE before sourcing.

# `esc to interrupt`: claude shows it while a turn is in flight, INCLUDING the
# auto-retry backoff on a transient 529 — so it must outrank a visible error line.
CLAUDE_WORKING_RE=${CLAUDE_WORKING_RE:-'esc to interrupt'}
# Numbered TUI menu — same anchor chat-watcher already used for `❯ N.`.
CLAUDE_MENU_RE=${CLAUDE_MENU_RE:-'^[[:space:]]*❯ [0-9]+\.'}
# API / usage / transport errors claude surfaces on the pane. Deliberately the
# claude BANNER forms (case-sensitive `API Error`, the structured error-type
# tokens `*_error`, full phrases) — NOT bare numbers (`529`/`500`) or lowercase
# "api error", which match ordinary prose. A session that merely DISCUSSES errors
# (e.g. a brew-ops dev working on this very feature) must not trip it. Combined
# with the bottom-region scan in classify_pane_state. (2026-06-17 self-watch FP.)
CLAUDE_ERROR_RE=${CLAUDE_ERROR_RE:-'API Error|overloaded_error|rate_limit_error|Request timed out|Internal server error|usage limit reached|Connection error|API request failed'}
# Any marker proving a claude TUI frame is rendered (vs a bare shell prompt).
CLAUDE_TUI_RE=${CLAUDE_TUI_RE:-'esc to interrupt|\? for shortcuts|❯ |⏵⏵|bypass permissions|/help for|Context (left|low)|auto-accept'}

# classify_pane_state "<pane_text>" "<pid_alive:1|0>" → echoes one state word.
classify_pane_state() {
  local pane="$1" pid_alive="${2:-1}"
  # A dead process is crashed even if the pane still shows a frozen frame.
  [ "$pid_alive" = "0" ] && { echo crashed; return; }
  # Empty/whitespace capture (transient tmux failure) — don't guess.
  [ -z "${pane//[[:space:]]/}" ] && { echo unknown; return; }
  # Order matters: working outranks a visible error (retry-in-progress); menu and
  # error outrank the idle/crash fallthrough.
  if printf '%s' "$pane" | grep -qE "$CLAUDE_WORKING_RE"; then echo working;  return; fi
  if printf '%s' "$pane" | grep -qE "$CLAUDE_MENU_RE";    then echo menu;     return; fi
  # api_error: scan ONLY the bottom active region (a real parked error banner sits
  # just above the input box). Scrollback prose that merely DISCUSSES errors
  # ("auto-resume 529", "hit an API error") must NOT trip it — the 2026-06-17
  # self-watch false positive where the watcher read this dev session's own summary.
  if printf '%s' "$pane" | grep -vE '^[[:space:]]*$' | tail -8 | grep -qE "$CLAUDE_ERROR_RE"; then
    echo api_error; return
  fi
  # No claude TUI marker at all → the process exited to the shell.
  if ! printf '%s' "$pane" | grep -qE "$CLAUDE_TUI_RE";   then echo crashed;   return; fi
  # claude TUI up, no work, no error → finished, parked at the prompt.
  echo idle_done
}

# pane_claude_alive "<pane_id>" → 0 if a `claude` process runs anywhere in the
# pane's process subtree, else 1. (Impure — tmux/ps; not unit-tested.)
pane_claude_alive() {
  local pane="$1" tpid p c kid
  tpid=$(tmux display-message -p -t "$pane" "#{pane_pid}" 2>/dev/null)
  [ -z "$tpid" ] && return 1
  local -a q=("$tpid"); local seen=" $tpid "
  while [ "${#q[@]}" -gt 0 ]; do
    p="${q[0]}"; q=("${q[@]:1}")
    c=$(ps -o command= -p "$p" 2>/dev/null)
    case "$c" in *claude*) return 0 ;; esac
    for kid in $(pgrep -P "$p" 2>/dev/null); do
      case "$seen" in *" $kid "*) continue ;; esac
      seen="$seen$kid "; q+=("$kid")
    done
  done
  return 1
}

# team_status_write <file> <chat_id> <state> [idle_count] — one-line JSON board
# entry the orchestrator can read instead of capture-pane-polling each teammate.
team_status_write() {
  local file="$1" chat="$2" state="$3" idlec="${4:-0}"
  [ -n "$file" ] || return 0
  printf '{"chat_id":"%s","state":"%s","idle_count":%s,"ts":%s,"iso":"%s"}\n' \
    "$chat" "$state" "${idlec:-0}" "$(date +%s)" "$(date -Iseconds)" > "$file" 2>/dev/null
}

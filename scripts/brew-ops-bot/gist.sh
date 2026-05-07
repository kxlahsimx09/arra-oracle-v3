#!/usr/bin/env bash
# gist.sh — shared "publish text as a secret GitHub Gist" helper.
# Sourced by both bot.sh (cmd_look fallback) and chat-watcher.sh (push_turn
# auto-push). Centralised so threshold + publish logic live in one place
# and stay in sync.
#
# Caller controls the file extension:
#   .md   for assistant turns / markdown — GitHub renders tables, code
#         fences, headings natively.
#   .txt  for raw tmux pane captures — preserves whitespace + monospaced
#         rendering without trying to interpret markdown (TUI
#         box-drawing characters look right, headings aren't faked).
#
# Requires `gh` on PATH with `gist` scope on the active account. Returns
# the gist URL on stdout when successful, empty on failure.

# Threshold for "long enough to deserve a gist" (chars). Both auto-push
# and /look use the same value so behaviour is consistent.
GIST_THRESHOLD=${GIST_THRESHOLD:-1500}

# gist_publish <title> <text> [extension]
gist_publish() {
  local title="$1" text="$2" ext="${3:-md}"
  command -v gh >/dev/null 2>&1 || return 1
  local safe; safe=$(echo "$title" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-')
  [ -z "$safe" ] && safe="brew-ops"
  local out url
  out=$(printf '%s' "$text" | gh gist create --filename "${safe}.${ext}" --desc "$title" - 2>/dev/null)
  url=$(echo "$out" | grep -Eo 'https://gist\.github\.com/[^[:space:]]+' | tail -1)
  [ -n "$url" ] && echo "$url"
}

#!/usr/bin/env bash
# cleanup-worktrees.sh — close idle maw-wake tmux panes + prune orphan worktrees
#
# A maw wake leaves behind a tmux window + a git worktree, even after the
# spawned claude exits. They accumulate over days. This script closes the
# idle ones safely.
#
# Safety rules:
#   1. Never touch the "<role>-oracle" root window of each session — those
#      are persistent agent anchors.
#   2. Never close a pane with claude still running (pane_current_command
#      looks like 2.x.x). That could kill a wake in progress.
#   3. Never remove a worktree with uncommitted work (`git worktree remove`
#      without --force refuses dirty trees — skip and warn).
#   4. Never remove a worktree that has a process with cwd inside it.
#   5. Never touch .claude/worktrees/ (IDE CCD worktrees — user's own).
#
# Usage:
#   bash cleanup-worktrees.sh             # dry-run (default) — preview only
#   bash cleanup-worktrees.sh --apply     # actually do it
#   bash cleanup-worktrees.sh --help

set -u
exec </dev/null

# ── Config ────────────────────────────────────────────────────────────────
# session -> oracle root window name (never touched)
declare -A ORACLE_ROOTS=(
  ["01-soul-brews"]="brew-ops-oracle"
  ["02-bank-bot"]="bot-writer-oracle"
  ["03-payment-gateway"]="pg-writer-oracle"
)

REPOS=(
  "$HOME/Code/github.com/kokarat/mobiz-payment-gateway"
  "$HOME/Code/github.com/kokarat/bank-bot"
  "$HOME/Code/github.com/Soul-Brews-Studio/arra-oracle-v3"
)

DRY_RUN=true
for arg in "$@"; do
  case $arg in
    --apply) DRY_RUN=false ;;
    --help|-h)
      head -30 "$0" | grep -E '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "unknown arg: $arg (see --help)"; exit 1 ;;
  esac
done

say() { echo "[cleanup] $*"; }
do_or_dry() {
  # usage: do_or_dry "<human description>" "<shell command>"
  local desc="$1"; shift
  if [ "$DRY_RUN" = "true" ]; then
    say "DRY-RUN would: $desc"
  else
    say "$desc"
    eval "$@" || say "  (failed, continuing)"
  fi
}

say "mode: $([ "$DRY_RUN" = "true" ] && echo 'DRY-RUN (use --apply to execute)' || echo 'APPLY')"

# ── Phase 1: close idle zsh panes ──────────────────────────────────────────
say ""
say "=== Phase 1: tmux panes ==="
killed_pane_count=0
kept_pane_count=0
skipped_pane_count=0

for sess in "${!ORACLE_ROOTS[@]}"; do
  oracle_root="${ORACLE_ROOTS[$sess]}"
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    say "session $sess not running — skip"
    continue
  fi

  # list windows; read into array to avoid subshell scoping issues
  windows=$(tmux list-windows -t "$sess" -F "#{window_index}|#{window_name}" 2>/dev/null)
  while IFS='|' read -r idx name; do
    [ -z "$idx" ] && continue
    if [ "$name" = "$oracle_root" ]; then
      kept_pane_count=$((kept_pane_count + 1))
      continue
    fi
    pane_info=$(tmux list-panes -t "${sess}:${idx}" -F "#{pane_pid} #{pane_current_command}" 2>/dev/null | head -1)
    pane_pid=$(echo "$pane_info" | awk '{print $1}')
    pane_cmd=$(echo "$pane_info" | awk '{print $2}')

    if [[ "$pane_cmd" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      say "SKIP active claude: $sess:$idx ($name) pid=$pane_pid cmd=$pane_cmd"
      skipped_pane_count=$((skipped_pane_count + 1))
      continue
    fi

    if [ "$pane_cmd" != "zsh" ] && [ "$pane_cmd" != "bash" ]; then
      say "SKIP unexpected command: $sess:$idx ($name) cmd=$pane_cmd"
      skipped_pane_count=$((skipped_pane_count + 1))
      continue
    fi

    # Interactive zsh ignores SIGTERM (shell job control). Use `tmux
    # kill-window` to tear down cleanly — tmux reaps the pane shell itself.
    do_or_dry "close idle pane $sess:$idx ($name) pid=$pane_pid" "tmux kill-window -t '${sess}:${idx}' 2>/dev/null"
    killed_pane_count=$((killed_pane_count + 1))
  done <<< "$windows"
done

say ""
say "panes: $killed_pane_count closed, $kept_pane_count oracle kept, $skipped_pane_count skipped (active)"

# Let tmux + git catch up
[ "$DRY_RUN" = "false" ] && sleep 3

# ── Phase 2: remove orphan worktrees ───────────────────────────────────────
say ""
say "=== Phase 2: git worktrees ==="
removed_count=0
kept_count=0
dirty_count=0

for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || continue
  say ""
  say "repo: $(basename "$repo")"

  # Iterate worktrees (porcelain output is "worktree <path>\nHEAD <sha>\nbranch <ref>\n\n" blocks)
  git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | \
  while read wt; do
    # Skip main repo (same path as $repo)
    [ "$wt" = "$repo" ] && continue
    # Skip .claude/worktrees/ (user's IDE CCD worktrees)
    [[ "$wt" == */.claude/worktrees/* ]] && continue

    # Check for processes with cwd in this worktree
    procs=$(lsof -d cwd 2>/dev/null | awk -v p="$wt" '$NF == p {print $2}' | wc -l | tr -d ' ')
    if [ "$procs" -gt 0 ]; then
      say "  KEEP (active processes=$procs): $(basename "$wt")"
      continue
    fi

    # "Real dirty" ignores .claude/.agent untracked symlinks that maw wake
    # creates in every worktree — those are infrastructure noise, not work.
    real_dirty=$(git -C "$wt" status --porcelain 2>/dev/null | grep -vE '^\?\? \.(claude|agent)' | head -1)

    if [ "$DRY_RUN" = "true" ]; then
      if [ -n "$real_dirty" ]; then
        say "  DRY-RUN would SKIP real-dirty: $(basename "$wt") ($real_dirty)"
      else
        say "  DRY-RUN would force-remove: $(basename "$wt")"
      fi
    else
      if [ -n "$real_dirty" ]; then
        say "  SKIP real-dirty: $(basename "$wt") ($real_dirty) — manual review needed"
        dirty_count=$((dirty_count + 1))
      else
        # Use --force since the only "dirt" is .claude/.agent symlinks
        if git -C "$repo" worktree remove --force "$wt" 2>/dev/null; then
          say "  removed: $(basename "$wt")"
          removed_count=$((removed_count + 1))
        else
          say "  SKIP (remove failed): $(basename "$wt")"
        fi
      fi
    fi
  done

  do_or_dry "git worktree prune ($(basename "$repo"))" "git -C '$repo' worktree prune"
done

say ""
say "=== Summary ==="
say "done. ($([ "$DRY_RUN" = "true" ] && echo 'DRY-RUN' || echo 'APPLIED'))"
[ "$DRY_RUN" = "true" ] && say "re-run with --apply to execute"

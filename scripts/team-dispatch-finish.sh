#!/usr/bin/env bash
# team-dispatch-finish.sh — orchestrator's campaign close-out for team-dispatch.
#
# What it does:
#   1. `maw team shutdown <campaign> --merge --force`
#      - sends structured shutdown to every live teammate via the team inbox,
#      - waits up to 30s for graceful exit,
#      - force-kills stragglers,
#      - --merge copies each member's accumulated inbox + *_findings.md to
#        ψ/memory/mailbox/<role>/ so the next reincarnation of that role inherits
#        "standing orders" + "last known findings",
#      - archives the manifest to ψ/memory/mailbox/teams/<campaign>/.
#   2. Removes every per-(campaign × repo) worktree this campaign opened:
#      `git worktree remove --force <repo>.wt-c-<campaign>` for each match.
#   3. `maw cleanup --zombie-agents --yes` — safety net for any orphan claude
#      pane that didn't belong to a live team config (e.g. a hand-spawned
#      teammate that the manifest forgot).
#
# Usage:
#   team-dispatch-finish.sh --campaign <slug>
#   team-dispatch-finish.sh --campaign <slug> --keep-worktrees   # debug only
#
# Owner: brew-ops.

set -uo pipefail
SCRIPT_NAME=$(basename "$0")
die() { printf '\033[31m✗\033[0m %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m⚠\033[0m %s\n' "$*"; }

CAMPAIGN=""; KEEP_WT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --campaign)        CAMPAIGN=${2:-}; shift 2 ;;
    --keep-worktrees)  KEEP_WT=1; shift ;;
    -h|--help)         sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 die "unknown arg: $1" ;;
  esac
done
[ -n "$CAMPAIGN" ] || die "missing --campaign"

GHQ_ROOT=$(ghq root 2>/dev/null) || die "ghq not installed"

echo "team-dispatch-finish: campaign=$CAMPAIGN"

# --- 1. maw team shutdown --merge --force ---
echo "→ maw team shutdown $CAMPAIGN --merge --force"
if maw team shutdown "$CAMPAIGN" --merge --force 2>&1 | sed 's/^/  /'; then
  ok "team shut down (findings merged to ψ/memory/mailbox/)"
else
  warn "shutdown reported an error — continuing to worktree cleanup"
fi

# --- 2. worktree removal ---
if [ -n "$KEEP_WT" ]; then
  warn "--keep-worktrees set; skipping worktree removal"
else
  echo "→ removing campaign worktrees matching *.wt-c-${CAMPAIGN}"
  found=0
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    found=$((found + 1))
    # owning repo is the wt path without the .wt-c-<slug> suffix
    repo="${wt%.wt-c-${CAMPAIGN}}"
    if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
      warn "orphan: $wt (owning repo missing at $repo)"
      continue
    fi
    if out=$(git -C "$repo" worktree remove --force "$wt" 2>&1); then
      ok "removed: $wt"
    else
      warn "failed to remove $wt — inspect manually:
    $out"
    fi
  done < <(find "$GHQ_ROOT" -maxdepth 5 -type d -name "*.wt-c-${CAMPAIGN}" 2>/dev/null)
  [ "$found" -eq 0 ] && echo "  (no worktrees matched *.wt-c-${CAMPAIGN})"
fi

# --- 3. zombie sweep (safety net) ---
echo "→ maw cleanup --zombie-agents --yes"
maw cleanup --zombie-agents --yes 2>&1 | sed 's/^/  /' || \
  warn "zombie sweep reported error (non-fatal)"

# --- 4. chat-watcher state cleanup ---
# chat-watcher.sh accumulates per-(role × campaign) state files keyed
# <role>_<campaign> that are never removed on close, so the cache grows
# unbounded. Purge this campaign's files across all roles (*_<campaign>).
# Specific globs + plain `rm -f` only — never a directory removal.
echo "→ purging chat-watcher state for *_${CAMPAIGN}"
STATE_DIR=${STATE_DIR:-$HOME/.cache/brew-ops-bot}
rm -f "$STATE_DIR"/idle-count.*_"$CAMPAIGN" \
      "$STATE_DIR"/idle-alerted.*_"$CAMPAIGN" \
      "$STATE_DIR"/idle-alerted-ts.*_"$CAMPAIGN" \
      "$STATE_DIR"/keepalive.*_"$CAMPAIGN"
ok "watcher state purged ($STATE_DIR/*_${CAMPAIGN})"

echo
ok "campaign $CAMPAIGN closed"

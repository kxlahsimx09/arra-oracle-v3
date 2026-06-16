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
#   1.5 Kills each teammate's helper-launched tmux window `<role>-<campaign>`.
#      maw shutdown only knows the panes IT spawned; the helper uses its own
#      `tmux new-window` (to set cwd), so without this the teammate's claude
#      survives IDLE after a "successful" finish and burns shared account quota
#      (the 2026-06-15 next-investigator session-limit). Runs even under
#      --keep-worktrees, then ASSERTS no `claude --agent-id …@<campaign>` is left.
#   2. Removes every per-(campaign × repo) worktree this campaign opened:
#      `git worktree remove --force <repo>.wt-c-<campaign>` for each match.
#   3. `maw cleanup --zombie-agents --yes` — safety net for any orphan claude
#      pane that didn't belong to a live team config (e.g. a hand-spawned
#      teammate that the manifest forgot).
#
# Usage:
#   team-dispatch-finish.sh --campaign <slug>
#   team-dispatch-finish.sh --campaign <slug> --keep-worktrees   # kill procs, keep trees
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

# --- 1.5 kill helper-launched teammate windows (maw shutdown misses these) ---
# WHY: team-dispatch-helper.sh spawns each teammate in its OWN window via
# `tmux new-window -n <role>-<campaign>` (outside maw's spawnTeammatePane, to set
# cwd). `maw team shutdown` only knows the panes IT spawned, so it leaves these
# windows running. The teammate's claude then stays ALIVE and idle after a
# "successful" finish, answering chat-watcher keepalive pings and BURNING SHARED
# ACCOUNT QUOTA (suspected cause of the next-investigator session-limit mid-L3 on
# 2026-06-15 — 3 finished-but-idle agents left running overnight). Kill by name.
#
# Runs even under --keep-worktrees: freeing the idle PROCESS is independent of
# whether a consumer (e.g. next-investigator still reading the worktree's
# evidence/) needs the FILES — so `--keep-worktrees` = kill process, keep tree.
#
# SAFETY: the helper names teammate windows `<role>-<campaign>`, so we match
# `*-<campaign>` but (a) NEVER an `orchestrator-*` window — that is this chain's
# own coordinator (`orchestrator-<slug>` also ends in `-<slug>` and would
# self-match), and (b) never the window we are running in.
echo "→ killing helper-launched teammate windows *-${CAMPAIGN}"
self_win=$(tmux display-message -p '#{window_name}' 2>/dev/null || true)
killed=0
while IFS= read -r win; do
  [ -z "$win" ] && continue
  case "$win" in orchestrator-*) continue ;; esac
  [ "$win" = "$self_win" ] && { warn "skipping current window $win"; continue; }
  if tmux kill-window -t "$win" 2>/dev/null; then
    ok "killed window $win"; killed=$((killed + 1))
  fi
done < <(tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -E -- "-${CAMPAIGN}\$")
[ "$killed" -eq 0 ] && echo "  (no live windows matched *-${CAMPAIGN}, excluding orchestrator/self)"

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
      # Best-effort: drop the now-unused campaign branch so a future dispatch
      # can't reuse a stale tip (workflow-2 path 2). SAFE delete only (-d,
      # merged-only) — never -D, per AGENTS.md §9 / CLAUDE.md no-force rule. An
      # unmerged branch is intentionally KEPT (its work isn't on origin/main
      # yet); the helper fast-forwards it on the next reuse, so staleness is
      # still handled either way.
      if git -C "$repo" show-ref --verify --quiet "refs/heads/campaign/${CAMPAIGN}"; then
        if git -C "$repo" branch -d "campaign/${CAMPAIGN}" >/dev/null 2>&1; then
          ok "deleted merged branch campaign/${CAMPAIGN}"
        else
          warn "kept branch campaign/${CAMPAIGN} (unmerged — safe-delete refused; ff'd on next reuse)"
        fi
      fi
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

# --- 5. assert no teammate process survived (the whole point of §1.5) ---------
# A finish that leaves a `claude --agent-id …@<campaign>` alive is the exact
# quota leak this script exists to prevent — surface it loudly instead of
# printing a clean "closed". Give the killed panes a moment to exit
# (kill-window → SIGHUP → claude flush/teardown can take ~1-3s).
echo "→ verifying no surviving teammate process for @${CAMPAIGN}"
alive=""
for _ in 1 2 3 4 5; do
  alive=$(pgrep -af "claude --agent-id" 2>/dev/null \
            | grep -E -- "@${CAMPAIGN}( |\$)" \
            | grep -v 'agent-id orchestrator@' || true)
  [ -z "$alive" ] && break
  sleep 1
done
if [ -n "$alive" ]; then
  warn "agent process(es) STILL ALIVE for @${CAMPAIGN} — free manually (tmux kill-pane / kill <pid>):
$alive"
else
  ok "verified: no surviving claude --agent-id …@${CAMPAIGN} process"
fi

echo
ok "campaign $CAMPAIGN closed"

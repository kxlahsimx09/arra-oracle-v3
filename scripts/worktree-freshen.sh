#!/usr/bin/env bash
# worktree-freshen.sh — bring a campaign worktree up to date with origin/main
# before a teammate starts working in it (workflow-2 "hybrid refresh" policy).
#
# WHY THIS EXISTS
#   team-dispatch-helper.sh only ever based freshness off origin/main on the
#   ONE path that creates a brand-new branch. The two other paths — reuse of an
#   existing <repo>.wt-c-<slug> dir, and checkout of an already-existing
#   campaign/<slug> branch — inherited a stale tip and nothing ever advanced
#   them. A teammate dispatched into a campaign that has run for hours/days then
#   starts N commits behind real upstream. This script closes that gap for every
#   path that doesn't already base off fresh origin/main.
#
# POLICY (hybrid, safe-by-default)
#   • Always: git fetch origin main (offline → warn on stderr, never fatal).
#   • "Advance" is FAST-FORWARD-ONLY (git merge --ff-only). It never rebases,
#     never rewrites, never force-pushes — honoring AGENTS.md §9 / the repo's
#     no-force rule. A ff is attempted only when ALL hold:
#         - branch has NO local commits ahead of origin/main (ahead == 0)
#           → rewriting published campaign work is never risked,
#         - working tree is clean (no teammate mid-edit),
#         - mode=reuse only: no sibling teammate window is live in the worktree.
#   • When a clean ff is not possible, the worktree is LEFT UNTOUCHED and a
#     staleness banner is emitted on stdout. The helper prepends it to the
#     teammate's kickoff turn so the agent owns the reconciliation (how) — per
#     the orchestrator "I don't do the work" philosophy.
#
# MODES
#   --mode checkout : worktree was just created from an existing branch; no
#                     agent is in it yet (dirty/live checks are moot).
#   --mode reuse    : shared worktree that may already hold a live teammate.
#
# OUTPUT  staleness banner on stdout (empty when fresh / advanced clean).
# EXIT    always 0 — freshness is best-effort and must never block a dispatch.
#
# Usage:
#   worktree-freshen.sh --repo <repo_path> --wt <wt_path> \
#                       --campaign <slug> --mode reuse|checkout
#
# Owner: brew-ops. Paired with team-dispatch-helper.sh.

set -uo pipefail
warn() { printf '\033[33m⚠\033[0m worktree-freshen: %s\n' "$*" >&2; }

REPO=""; WT=""; CAMPAIGN=""; MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO=${2:-};     shift 2 ;;
    --wt)       WT=${2:-};       shift 2 ;;
    --campaign) CAMPAIGN=${2:-}; shift 2 ;;
    --mode)     MODE=${2:-};     shift 2 ;;
    *) warn "unknown arg: $1"; exit 0 ;;
  esac
done
# Missing inputs must not break a dispatch — degrade to a no-op.
[ -n "$REPO" ] && [ -n "$WT" ] && [ -n "$MODE" ] || { warn "missing args; skipping"; exit 0; }
[ -d "$WT" ] || { warn "worktree $WT not found; skipping"; exit 0; }

# 1. Always refresh origin/main (idempotent; safe if the helper already fetched).
git -C "$REPO" fetch origin main --quiet 2>/dev/null \
  || warn "fetch origin main failed (offline?) — comparing against existing origin/main"

# 2. How far behind is the worktree's branch?
behind=$(git -C "$WT" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
[ "${behind:-0}" -eq 0 ] && exit 0   # already current → nothing to do, no banner

ahead=$(git -C "$WT" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
dirty=$(git -C "$WT" status --porcelain 2>/dev/null)
short=$(git -C "$WT" rev-parse --short origin/main 2>/dev/null)

# A sibling teammate already in this shared worktree = a window named *-<campaign>.
# (The new teammate's window doesn't exist yet — helper creates it after this.)
live=""
if [ "$MODE" = "reuse" ] && [ -n "$CAMPAIGN" ]; then
  live=$(tmux list-windows -a -F '#{window_name}' 2>/dev/null \
           | grep -E -- "-${CAMPAIGN}\$" | head -1)
fi

banner() {
  cat <<EOF
⚠ STALE BASE — this worktree is ${behind} commit(s) behind origin/main (${short}).
Auto-advance was skipped: $1.
Reconcile before you rely on the tree, e.g. \`git merge origin/main\` (or rebase if you know the branch is unpublished). Treat code/tests read so far as possibly out of date.
EOF
}

# 3. Decide: clean fast-forward, or leave-and-warn.
if [ "$ahead" -gt 0 ]; then
  banner "branch has ${ahead} local commit(s) ahead of origin/main — advancing would rewrite published work"
elif [ -n "$dirty" ]; then
  banner "working tree has uncommitted changes (a teammate may be mid-edit)"
elif [ -n "$live" ]; then
  banner "sibling teammate window '${live}' is live in this shared worktree"
elif git -C "$WT" merge --ff-only origin/main >/dev/null 2>&1; then
  warn "fast-forwarded $WT +${behind} → ${short} (clean, no rewrite)"   # stderr note, no banner
else
  banner "fast-forward refused (diverged unexpectedly)"
fi
exit 0

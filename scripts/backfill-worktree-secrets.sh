#!/usr/bin/env bash
# backfill-worktree-secrets.sh — link `.secrets` in a repo's worktrees to the
# central fleet secret store.
#
# Companion to maw-js `injectWorktreeSymlinks()` (src/commands/shared/
# wake-session.ts): maw injects `.secrets` into NEW worktrees at creation/wake;
# this script backfills worktrees that already existed before that wiring
# landed. One-time per repo, but idempotent — safe to re-run.
#
# Usage:   scripts/backfill-worktree-secrets.sh <repo-name>
# Example: scripts/backfill-worktree-secrets.sh mb-next-payment-gateway
#
# Convention (the generalization point — onboarding a new repo is just this):
#   central store  →  ~/.arra-oracle-v2/fleet-secrets/<repo-name>/
# It lives outside any git repo and is the single source of truth. `.secrets`
# is gitignored, so the symlink is invisible to git — the same property the
# `.agent` symlink relies on. Worktrees only ever symlink to the store; no
# secret value is ever copied or committed.
set -euo pipefail

repo="${1:-}"
if [[ -z "$repo" ]]; then
  echo "usage: $0 <repo-name>" >&2
  exit 1
fi

store="$HOME/.arra-oracle-v2/fleet-secrets/$repo"
if [[ ! -d "$store" ]]; then
  echo "✗ no central store at $store — create + populate it first" >&2
  exit 1
fi

# Discover the primary checkout + every worktree (sibling `.wt-*` dirs).
shopt -s nullglob
targets=( "$HOME"/Code/github.com/*/"$repo" "$HOME"/Code/github.com/*/"$repo".wt-* )
if [[ ${#targets[@]} -eq 0 ]]; then
  echo "✗ no repo dirs found for '$repo' under ~/Code/github.com/*/" >&2
  exit 1
fi

linked=0 skipped=0 warned=0
for dir in "${targets[@]}"; do
  [[ -d "$dir" ]] || continue
  sec="$dir/.secrets"
  if [[ -L "$sec" ]]; then
    echo "  = $(basename "$dir")/.secrets already a symlink — skip"
    skipped=$((skipped + 1))
  elif [[ -d "$sec" ]]; then
    echo "  ! $(basename "$dir")/.secrets is a REAL dir — review against the store," >&2
    echo "    remove it by hand, then re-run (this script never deletes secrets)." >&2
    warned=$((warned + 1))
  elif [[ -e "$sec" ]]; then
    echo "  ! $(basename "$dir")/.secrets exists and is not a directory — skip" >&2
    warned=$((warned + 1))
  else
    ln -s "$store" "$sec"
    echo "  + $(basename "$dir")/.secrets → $store"
    linked=$((linked + 1))
  fi
done

echo "done: $linked linked, $skipped already-linked, $warned need manual review"

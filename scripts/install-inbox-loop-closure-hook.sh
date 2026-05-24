#!/usr/bin/env bash
# install-inbox-loop-closure-hook.sh
#
# Deploys inbox-loop-closure-hook.sh as a `Stop` hook for both Claude and
# Codex runtimes so the §11d loop-closure policy is enforced engine-agnostic.
# The hook self-gates: it is a no-op for any session not spawned by the
# inbox-watcher, so global runtime-level install is safe.
#
# What it does (idempotent — safe to re-run):
#   1. copies the hook to ~/.claude/hooks/ and ~/.codex/hooks/
#   2. backs up ~/.claude/settings.json and ~/.codex/hooks.json
#   3. adds the hook to .hooks.Stop if not already registered
#
# Re-run this after editing scripts/inbox-loop-closure-hook.sh — the repo
# copy is the source of truth; runtime hook dirs hold the deployed copy.
#
# Owner: brew-ops. See AGENTS.md §11l.

set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$SRC_DIR/inbox-loop-closure-hook.sh"

[ -f "$SRC" ] || { echo "✗ source hook not found: $SRC" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }

register_stop_hook() { # $1=runtime $2=hooks_dir $3=settings_json
  local runtime=$1 hooks_dir=$2 settings=$3 dest backup tmp
  dest="$hooks_dir/inbox-loop-closure-hook.sh"

  mkdir -p "$hooks_dir"
  cp "$SRC" "$dest"
  chmod +x "$dest"
  echo "✓ [$runtime] hook deployed: $dest"

  if [ ! -f "$settings" ]; then
    mkdir -p "$(dirname "$settings")"
    echo '{}' >"$settings"
    echo "✓ [$runtime] created $settings"
  fi

  if jq -e --arg c "$dest" '[.hooks.Stop[]?.hooks[]?.command] | index($c)' \
       "$settings" >/dev/null 2>&1; then
    echo "• [$runtime] already registered in $settings — nothing to do"
    return 0
  fi

  backup="$settings.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$settings" "$backup"
  echo "✓ [$runtime] backed up settings → $backup"

  tmp=$(mktemp)
  jq --arg c "$dest" \
    '.hooks.Stop = ((.hooks.Stop // []) +
      [{"hooks": [{"type": "command", "command": $c}]}])' \
    "$settings" >"$tmp"
  mv "$tmp" "$settings"
  echo "✓ [$runtime] registered Stop hook in $settings"
}

# Claude runtime
register_stop_hook "claude" "$HOME/.claude/hooks" "$HOME/.claude/settings.json"
# Codex runtime
register_stop_hook "codex" "$HOME/.codex/hooks" "$HOME/.codex/hooks.json"
echo
echo "Done. New oracle sessions (Claude/Codex) are now gated by §11d loop-closure."

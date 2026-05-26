#!/usr/bin/env bash
# install-orchestrator-guard-hook.sh
#
# Deploys orchestrator-guard-hook.sh as a `PreToolUse` hook (matcher
# Edit|Write|MultiEdit) in the Claude runtime. The hook self-gates on the tmux
# window name, so it is a no-op for every session except the orchestrator's
# (`orchestrator-oracle`) — a fleet-wide user-level install is therefore safe
# and does not restrict brew-ops / writer / tester / architect edit rights.
#
# Claude-only by design: the orchestrator runs on the `claude` engine. PreToolUse
# hooks still run and can still block under `--dangerously-skip-permissions`,
# which is exactly how the orchestrator is launched.
#
# What it does (idempotent — safe to re-run):
#   1. copies the hook to ~/.claude/hooks/
#   2. backs up ~/.claude/settings.json
#   3. adds the hook to .hooks.PreToolUse (matcher Edit|Write|MultiEdit) if absent
#
# Re-run this after editing scripts/orchestrator-guard-hook.sh — the repo copy
# is the source of truth; the runtime hook dir holds the deployed copy.
#
# Owner: brew-ops. See AGENTS.md and orchestrator/SKILL.md §Scope guard.

set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$SRC_DIR/orchestrator-guard-hook.sh"
MATCHER="Edit|Write|MultiEdit"

[ -f "$SRC" ] || { echo "✗ source hook not found: $SRC" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }

hooks_dir="$HOME/.claude/hooks"
settings="$HOME/.claude/settings.json"
dest="$hooks_dir/orchestrator-guard-hook.sh"

mkdir -p "$hooks_dir"
cp "$SRC" "$dest"
chmod +x "$dest"
echo "✓ hook deployed: $dest"

if [ ! -f "$settings" ]; then
  mkdir -p "$(dirname "$settings")"
  echo '{}' >"$settings"
  echo "✓ created $settings"
fi

if jq -e --arg c "$dest" '[.hooks.PreToolUse[]?.hooks[]?.command] | index($c)' \
     "$settings" >/dev/null 2>&1; then
  echo "• already registered in $settings — nothing to do"
  exit 0
fi

backup="$settings.bak-$(date +%Y%m%d-%H%M%S)"
cp "$settings" "$backup"
echo "✓ backed up settings → $backup"

tmp=$(mktemp)
jq --arg c "$dest" --arg m "$MATCHER" \
  '.hooks.PreToolUse = ((.hooks.PreToolUse // []) +
    [{"matcher": $m, "hooks": [{"type": "command", "command": $c}]}])' \
  "$settings" >"$tmp"
mv "$tmp" "$settings"
echo "✓ registered PreToolUse hook (matcher: $MATCHER) in $settings"

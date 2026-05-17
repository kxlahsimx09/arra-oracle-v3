#!/usr/bin/env bash
# install-inbox-loop-closure-hook.sh
#
# Deploys inbox-loop-closure-hook.sh as a Claude Code `Stop` hook so it runs
# for every claude session on this (single) node — including every oracle
# pane the inbox-watcher spawns. The hook self-gates: it is a no-op for any
# session not spawned by the inbox-watcher, so a global install is safe.
#
# What it does (idempotent — safe to re-run):
#   1. copies the hook to ~/.claude/hooks/inbox-loop-closure-hook.sh
#   2. backs up ~/.claude/settings.json
#   3. adds the hook to .hooks.Stop if not already registered
#
# Re-run this after editing scripts/inbox-loop-closure-hook.sh — the repo
# copy is the source of truth; ~/.claude/hooks/ holds the deployed copy.
#
# Owner: brew-ops. See AGENTS.md §11l.

set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$SRC_DIR/inbox-loop-closure-hook.sh"
HOOKS_DIR="$HOME/.claude/hooks"
DEST="$HOOKS_DIR/inbox-loop-closure-hook.sh"
SETTINGS="$HOME/.claude/settings.json"

[ -f "$SRC" ] || { echo "✗ source hook not found: $SRC" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }

# 1. deploy the hook script
mkdir -p "$HOOKS_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "✓ hook deployed: $DEST"

# 2. ensure settings.json exists
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' >"$SETTINGS"
  echo "✓ created $SETTINGS"
fi

# 3. register in .hooks.Stop (idempotent)
if jq -e --arg c "$DEST" '[.hooks.Stop[]?.hooks[]?.command] | index($c)' \
     "$SETTINGS" >/dev/null 2>&1; then
  echo "• already registered in $SETTINGS — nothing to do"
  exit 0
fi

backup="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$backup"
echo "✓ backed up settings → $backup"

tmp=$(mktemp)
jq --arg c "$DEST" \
  '.hooks.Stop = ((.hooks.Stop // []) +
    [{"hooks": [{"type": "command", "command": $c}]}])' \
  "$SETTINGS" >"$tmp"
mv "$tmp" "$SETTINGS"
echo "✓ registered Stop hook in $SETTINGS"
echo
echo "Done. New oracle sessions are now gated by §11d loop-closure."
echo "To uninstall: restore $backup"

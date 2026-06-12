#!/usr/bin/env bash
# install-launchd-fts-reindex.sh — install the periodic STEP-1 (FTS) vault
# auto-ingest job as a launchd agent.
#
# Renders scripts/launchd/com.soulbrews.fts-reindex.plist (substituting
# __ARRA__ / __HOME__ / __VAULT__) into ~/Library/LaunchAgents and loads it.
# Idempotent: unloads any existing instance first. Mirrors
# install-launchd-janitor.sh. See the runbook in the vault:
#   ψ/memory/runbooks/fts-reindex-auto-ingest.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARRA="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.soulbrews.fts-reindex"
SRC="$SCRIPT_DIR/launchd/$LABEL.plist"
DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.cache/soul-brews-startup"

# Resolve the vault git root (ghq first, then the canonical checkout path).
VAULT="$(ghq list -p kxlahsimx09/mb_agent_oracle_memory 2>/dev/null | head -1 || true)"
[ -z "${VAULT:-}" ] && VAULT="$HOME/Code/github.com/kxlahsimx09/mb_agent_oracle_memory"
if [ ! -d "$VAULT/.git" ]; then
  echo "✗ vault git root not found at: $VAULT" >&2
  echo "  set it explicitly:  VAULT=/path/to/mb_agent_oracle_memory $0" >&2
  exit 1
fi
VAULT="${VAULT_OVERRIDE:-$VAULT}"

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents" "$HOME/.cache/fts-reindex"

# Stop any existing instance (idempotent reinstall)
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
  echo "→ unloading existing $LABEL"
  launchctl unload "$DST" 2>/dev/null || true
fi

# Render placeholders → final plist
sed -e "s#__ARRA__#$ARRA#g" -e "s#__HOME__#$HOME#g" -e "s#__VAULT__#$VAULT#g" "$SRC" > "$DST"
echo "✓ rendered $DST"
echo "  ARRA  = $ARRA"
echo "  VAULT = $VAULT"

launchctl load "$DST"
echo "✓ loaded $LABEL"

sleep 2
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
  echo "✓ fts-reindex is scheduled (STEP 1 only, every 15m, change-detected)"
  echo "  launchd log:  $LOG_DIR/fts-reindex.launchd.log"
  echo "  job log:      $HOME/.cache/fts-reindex/fts-reindex.log"
  echo "  heartbeat:    $HOME/.cache/fts-reindex/last-run  (stale mtime ⇒ job dead)"
  echo ""
  echo "Commands:"
  echo "  stop:    launchctl unload ~/Library/LaunchAgents/$LABEL.plist"
  echo "  start:   launchctl load   ~/Library/LaunchAgents/$LABEL.plist"
  echo "  status:  launchctl list | grep fts-reindex"
  echo "  run now: ARRA=$ARRA ORACLE_REPO_ROOT=$VAULT bash $ARRA/scripts/fts-reindex.sh --force"
else
  echo "⚠ did not start — check $LOG_DIR/fts-reindex.launchd.log"
fi

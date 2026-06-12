#!/usr/bin/env bash
# install-launchd-janitor.sh — install worktree-janitor as a launchd agent.
#
# Renders scripts/launchd/com.soulbrews.worktree-janitor.plist (substituting
# __ARRA__ / __HOME__) into ~/Library/LaunchAgents and loads it. Idempotent:
# unloads any existing instance first. Mirrors install-inbox-watcher-supervisor.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARRA="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.soulbrews.worktree-janitor"
SRC="$SCRIPT_DIR/launchd/$LABEL.plist"
DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.cache/soul-brews-startup"

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Stop any existing instance (idempotent reinstall)
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
  echo "→ unloading existing $LABEL"
  launchctl unload "$DST" 2>/dev/null || true
fi

# Render placeholders → final plist
sed -e "s#__ARRA__#$ARRA#g" -e "s#__HOME__#$HOME#g" "$SRC" > "$DST"
echo "✓ rendered $DST"

launchctl load "$DST"
echo "✓ loaded $LABEL"

sleep 2
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
  echo "✓ worktree-janitor is running (JANITOR_AUTO=1, scan every 4h)"
  echo "  log: $LOG_DIR/worktree-janitor.launchd.log"
  echo "  janitor state/log: $HOME/.cache/worktree-janitor/janitor.log"
  echo ""
  echo "Commands:"
  echo "  stop:    launchctl unload ~/Library/LaunchAgents/$LABEL.plist"
  echo "  start:   launchctl load ~/Library/LaunchAgents/$LABEL.plist"
  echo "  status:  launchctl list | grep worktree-janitor"
else
  echo "⚠ did not start — check $LOG_DIR/worktree-janitor.launchd.log"
fi

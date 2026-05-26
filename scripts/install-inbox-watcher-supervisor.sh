#!/usr/bin/env bash
# Install the launchd supervisor for the directed-inbox watcher (thread #224).
#
# start-soul-brews.sh starts the watcher at login and verifies it 5s later,
# then exits — a death AFTER that window (the 2026-05-16 fd-storm; thread
# #224's heavy gc sweep) was never noticed and left dispatch offline ~24h on
# 2026-05-25. This installs a dedicated KeepAlive=true launchd job so any exit
# self-heals.
#
# Idempotent. Order matters: tear the job down, stop the running daemon and
# WAIT for it to actually exit (inbox-watcher.sh traps TERM but defers it until
# the current gc sweep returns — a slow stop is normal), THEN (re)load. Loading
# while the old process is still dying makes the new instance hit
# find_other_daemons and bail, leaving a KeepAlive respawn-fail loop.
#
# NOTE ON SESSIONS: launchd only honours RunAtLoad/KeepAlive in the user's GUI
# (Aqua) login session. Run this from Terminal.app, or just install the plist
# and let it activate at next login. From a Background/SSH session the kickstart
# below still starts it, but automatic restart is owned by the login session.
set -euo pipefail

ARRA=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ARRA/scripts/launchd/com.soulbrews.inbox-watcher.plist"
LABEL=com.soulbrews.inbox-watcher
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.cache/soul-brews-startup"

# Render template → installed plist.
sed -e "s|__ARRA__|$ARRA|g" -e "s|__HOME__|$HOME|g" "$TEMPLATE" >"$PLIST"
echo "rendered $PLIST (ARRA=$ARRA)"

# 1. Tear down any existing job so it can't respawn-fight the stop below.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true

# 2. Stop any running watcher (nohup- or launchd-spawned) and WAIT for exit.
#    inbox-watcher.sh guards against double-start, so the reloaded job must own
#    exactly one daemon. TERM is deferred until the current gc sweep returns —
#    poll up to 40s rather than racing launchctl load.
bash "$ARRA/scripts/inbox-watcher.sh" stop 2>/dev/null || true
for _ in $(seq 1 40); do
  pgrep -f "inbox-watcher.sh start" >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -f "inbox-watcher.sh start" >/dev/null 2>&1; then
  echo "✗ a watcher is still running after 40s — not loading the job to avoid a" >&2
  echo "  KeepAlive respawn-fail loop. Stop it manually, then re-run this." >&2
  exit 1
fi

# 3. Load + enable, then kickstart so it runs immediately (RunAtLoad covers the
#    login case; kickstart covers running it now from any session).
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl kickstart "$DOMAIN/$LABEL" 2>/dev/null || true
echo "loaded $LABEL"

# 4. Verify a daemon came up.
for _ in 1 2 3 4 5 6; do
  if pgrep -f "inbox-watcher.sh start" >/dev/null 2>&1; then
    echo "✓ inbox-watcher up (pid $(pgrep -f 'inbox-watcher.sh start' | tr '\n' ' '))"
    echo
    echo "NOTE: KeepAlive auto-restart is honoured by the GUI login session. If you"
    echo "ran this from a Background/SSH session, it is running now but will only"
    echo "self-heal after the next login (when the Aqua session loads the plist)."
    echo "start-soul-brews.sh also starts the watcher at login but is proc_alive-"
    echo "guarded and starts it last, so it will defer to this job."
    exit 0
  fi
  sleep 1
done

echo "✗ inbox-watcher did not come up — see $HOME/.cache/soul-brews-startup/inbox-watcher.launchd.log" >&2
exit 1

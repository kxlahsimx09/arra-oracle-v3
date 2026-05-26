#!/usr/bin/env bash
# Install the launchd supervisor for the directed-inbox watcher (thread #224).
#
# start-soul-brews.sh starts the watcher at login and verifies it 5s later,
# then exits — a death AFTER that window (the 2026-05-16 fd-storm; thread
# #224's heavy gc sweep) was never noticed and left dispatch offline ~24h on
# 2026-05-25. This installs a dedicated KeepAlive=true launchd job so any exit
# self-heals.
#
# Idempotent: re-render the plist, stop any existing watcher so the reloaded
# job owns a single daemon, (re)load the job, verify it comes up.
set -euo pipefail

ARRA=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ARRA/scripts/launchd/com.soulbrews.inbox-watcher.plist"
LABEL=com.soulbrews.inbox-watcher
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.cache/soul-brews-startup"

# Render template → installed plist.
sed -e "s|__ARRA__|$ARRA|g" -e "s|__HOME__|$HOME|g" "$TEMPLATE" >"$PLIST"
echo "rendered $PLIST (ARRA=$ARRA)"

# Stop any existing instance first. inbox-watcher.sh guards against double-start
# (PID_FILE + find_other_daemons), so a KeepAlive job racing a leftover
# nohup-spawned watcher would respawn-fail every ThrottleInterval — clear the
# field so the reloaded job owns exactly one daemon.
bash "$ARRA/scripts/inbox-watcher.sh" stop 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true

launchctl load -w "$PLIST"
echo "loaded $LABEL"

# Verify up (RunAtLoad should spawn it immediately).
for _ in 1 2 3 4 5 6; do
  if pgrep -f "inbox-watcher.sh start" >/dev/null 2>&1; then
    echo "✓ inbox-watcher up under launchd (pid $(pgrep -f 'inbox-watcher.sh start' | tr '\n' ' '))"
    echo
    echo "NOTE: start-soul-brews.sh also starts inbox-watcher at login, but it is"
    echo "proc_alive-guarded and starts the watcher LAST, so it will skip when this"
    echo "launchd job already owns it. For a single clear owner you may remove the"
    echo "'inbox-watcher' start_proc_svc line from start-soul-brews.sh."
    exit 0
  fi
  sleep 1
done

echo "✗ inbox-watcher did not come up — see $HOME/.cache/soul-brews-startup/inbox-watcher.launchd.log" >&2
exit 1

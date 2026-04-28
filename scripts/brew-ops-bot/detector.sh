#!/usr/bin/env bash
# brew-ops-bot detector — push alerts on new [BLOCK_*] / [SECURITY_HOLD:*]
# markers landing in main, and on resolution.
#
# Runs as a separate long-running process from bot.sh so that bot.sh's
# Telegram long-poll isn't blocked by detector work.
#
# Poll cadence: $POLL seconds (default 300 = 5 min).
# State: $STATE_DIR/seen-blockers.txt — sorted unique list of marker
# strings. First run primes the list (no alerts on first scan).

set -u
exec </dev/null

ENV_FILE=${ENV_FILE:-$HOME/.cache/brew-ops-bot/.env}
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a

TOKEN=${BREW_OPS_BOT_TOKEN:-}
CHAT=${BREW_OPS_BOT_CHAT:-}
[ -z "$TOKEN" ] || [ -z "$CHAT" ] && { echo "ERR: env missing in $ENV_FILE"; exit 1; }

STATE_DIR=${STATE_DIR:-$HOME/.cache/brew-ops-bot}
mkdir -p "$STATE_DIR"
LOG_FILE=${DETECTOR_LOG_FILE:-$STATE_DIR/detector.log}
SEEN_FILE=$STATE_DIR/seen-blockers.txt
touch "$SEEN_FILE"

REPOS=(
  "$HOME/Code/github.com/kokarat/mobiz-payment-gateway"
  "$HOME/Code/github.com/kokarat/bank-bot"
  "$HOME/Code/github.com/Soul-Brews-Studio/arra-oracle-v3"
)

POLL=${POLL:-300}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

send_tg() {
  curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=$CHAT" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" \
    -o /dev/null 2>/dev/null
}

# Scan all repos, return sorted-unique list of "<repo>:<file>:<marker>" lines
scan() {
  for repo in "${REPOS[@]}"; do
    [ ! -d "$repo/docs" ] && continue
    grep -rEn '\[(BLOCK_[A-Z_]+|SECURITY_HOLD):[0-9]+\]' "$repo/docs" 2>/dev/null \
      | sed "s|^$repo/||"
  done | sort -u
}

log "detector starting (pid=$$, poll=${POLL}s)"
trap 'log "shutting down (pid=$$)"; exit 0' INT TERM

# First scan primes baseline without alerting
if [ ! -s "$SEEN_FILE" ]; then
  scan > "$SEEN_FILE"
  log "primed baseline ($(wc -l < "$SEEN_FILE" | tr -d ' ') markers seen)"
fi

while true; do
  current=$(scan)
  seen=$(cat "$SEEN_FILE")

  new=$(comm -23 <(echo "$current") <(echo "$seen"))
  resolved=$(comm -13 <(echo "$current") <(echo "$seen"))

  if [ -n "$new" ]; then
    log "NEW blocker(s):
$new"
    send_tg "🔴 <b>NEW blocker(s) detected ใน main</b>
<pre>$new</pre>"
  fi
  if [ -n "$resolved" ]; then
    log "RESOLVED blocker(s):
$resolved"
    send_tg "🟢 <b>Resolved blocker(s)</b>
<pre>$resolved</pre>"
  fi

  echo "$current" > "$SEEN_FILE"
  sleep "$POLL"
done

#!/usr/bin/env bash
# brew-ops-bot fleet-health — alert-only check for primary-checkout drift.
#
# Surfaces (it never mutates a checkout — P-003: surface, don't command) the
# two failure modes the #181 4-FIX bundle does NOT prevent (thread #204):
#
#   PARKED  primary's working tree is on a feature branch instead of its
#           canonical branch (the mb-next dark-theme 9-day park, §3c).
#   STALE   primary is ON its canonical branch but behind the canonical
#           upstream — the "merge-then-pull skipped" deploy-gap (§3c.2):
#           code merged to the integration branch but never ff'd into the
#           running checkout. (Both runtime primaries were behind by 2 on
#           2026-05-22 — the gap that surfaced this very check.)
#
# The 4-FIX (maw-js#8, arra#85) only ff's the local <default> REF + branches
# fresh worktrees off origin/HEAD; nothing ever `git switch`es a primary off
# a parked branch or ff's the checked-out branch. This check is the
# recurrence-prevention layer: detect → Telegram alert → human runs the
# §3c.4-verify-then-resync by hand (or scripts/resync-primary.sh, separate PR).
#
# Modes:
#   fleet-health.sh                 one scan, alert on transitions, exit
#   fleet-health.sh --watch         poll every $POLL seconds (default 1800)
#   fleet-health.sh --dry-run       print what it WOULD send; no Telegram, no state
#   fleet-health.sh --no-fetch      skip `git fetch` (use current remote-tracking refs)
#
# Dedup: state per primary in $STATE_DIR/fleet-health/<sanitized>.state
#        (sig|first_seen|last_alert). Alert on signature change; re-nag every
#        $RENAG seconds (default 86400) while a problem persists; 🟢 on resolve.
#
# Telegram env (same as detector.sh): $HOME/.cache/brew-ops-bot/.env →
# BREW_OPS_BOT_TOKEN + BREW_OPS_BOT_CHAT. --dry-run does not require them.

set -u
exec </dev/null

DRY=0; WATCH=0; DO_FETCH=1
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --watch)   WATCH=1 ;;
    --no-fetch) DO_FETCH=0 ;;
    --help|-h) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ENV_FILE=${ENV_FILE:-$HOME/.cache/brew-ops-bot/.env}
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a
TOKEN=${BREW_OPS_BOT_TOKEN:-}
CHAT=${BREW_OPS_BOT_CHAT:-}
if [ "$DRY" = 0 ] && { [ -z "$TOKEN" ] || [ -z "$CHAT" ]; }; then
  echo "ERR: BREW_OPS_BOT_TOKEN / BREW_OPS_BOT_CHAT missing in $ENV_FILE (use --dry-run to test)" >&2
  exit 1
fi

STATE_ROOT=${STATE_DIR:-$HOME/.cache/brew-ops-bot}
STATE_DIR="$STATE_ROOT/fleet-health"
[ "$DRY" = 0 ] && mkdir -p "$STATE_DIR"
LOG_FILE=${FLEET_HEALTH_LOG_FILE:-$STATE_ROOT/fleet-health.log}
POLL=${POLL:-1800}
RENAG=${RENAG:-86400}

# Canonical-branch map per AGENTS.md §3c. Format: path|expected_branch|remote.
# arra-oracle-v3 + maw-js are runtime primaries pinned to feat/all-prs-rebased
# (deploy source-of-truth) on the fork; mb-next's local main is the freshness
# anchor every maw-spawned wt inherits.
PRIMARIES=(
  "$HOME/Code/github.com/Soul-Brews-Studio/arra-oracle-v3|feat/all-prs-rebased|fork"
  "$HOME/Code/github.com/Soul-Brews-Studio/maw-js|feat/all-prs-rebased|fork"
  "$HOME/Code/github.com/kxlahsimx09/mb-next-payment-gateway|main|origin"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
sanitize() { echo "$1" | tr '/ .' '___'; }
esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

human_duration() {
  local s=$1 d h m
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"; fi
}

send_tg() {
  curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=$CHAT" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" \
    -o /dev/null 2>/dev/null
}

emit() {  # $1 = HTML body
  if [ "$DRY" = 1 ]; then
    printf -- '--- WOULD SEND ---\n%s\n' "$1"
  else
    send_tg "$1"
    log "alert sent:
$1"
  fi
}

# Sets ASSESS_STATUS (OK|PARKED|STALE|MISSING|NOCANON), ASSESS_SIG, ASSESS_BODY.
# ASSESS_BODY carries a %DUR% token the caller replaces with the parked duration.
assess_primary() {
  local path=$1 expected=$2 remote=$3 name; name=$(basename "$path")
  ASSESS_STATUS=OK; ASSESS_SIG="ok"; ASSESS_BODY=""

  if [ ! -e "$path/.git" ]; then
    ASSESS_STATUS=MISSING; ASSESS_SIG="missing"
    ASSESS_BODY="⚪ <b>Primary missing: ${name}</b>
<code>${path}</code> is not a git checkout"
    return
  fi
  [ "$DO_FETCH" = 1 ] && git -C "$path" fetch "$remote" --quiet 2>/dev/null

  local canon="${remote}/${expected}"
  if ! git -C "$path" rev-parse --verify --quiet "$canon" >/dev/null 2>&1; then
    ASSESS_STATUS=NOCANON; ASSESS_SIG="nocanon"
    ASSESS_BODY="⚪ <b>Fleet-health skipped: ${name}</b>
canonical ref <code>${canon}</code> not found (offline / remote missing?)"
    return
  fi

  local cur behind ahead dirty unpushed
  cur=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
  behind=$(git -C "$path" rev-list --count "HEAD..${canon}" 2>/dev/null || echo 0)
  ahead=$(git -C "$path" rev-list --count "${canon}..HEAD" 2>/dev/null || echo 0)
  dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  unpushed=$(git -C "$path" log --oneline '@{u}..' 2>/dev/null | wc -l | tr -d ' ')

  if [ "$cur" != "$expected" ]; then
    ASSESS_STATUS=PARKED; ASSESS_SIG="parked:${cur}:${behind}:${ahead}:${dirty}"
    local stat; stat=$(git -C "$path" diff --shortstat "$canon" HEAD 2>/dev/null | sed 's/^ *//' | esc)
    [ -z "$stat" ] && stat="(no working-tree diff vs canonical)"
    ASSESS_BODY="🟠 <b>Primary parked: ${name}</b>
on <code>$(echo "$cur" | esc)</code> (expected <code>${expected}</code>)%DUR%
vs <code>${canon}</code>: behind ${behind}, ahead ${ahead}
<pre>${stat}</pre>dirty ${dirty} · unpushed ${unpushed}
→ §3c.4 verify-before-discard, then re-sync by hand"
    return
  fi

  if [ "${behind:-0}" -gt 0 ]; then
    ASSESS_STATUS=STALE; ASSESS_SIG="stale:${behind}"
    local missing fixhint; missing=$(git -C "$path" log --oneline "HEAD..${canon}" 2>/dev/null | head -4 | esc)
    fixhint="git fetch ${remote} && git merge --ff-only ${canon}"
    [ "$name" = "arra-oracle-v3" ] && fixhint="${fixhint}; then restart inbox-watcher (stop→start)"
    ASSESS_BODY="🟠 <b>Primary stale: ${name}</b>
on <code>${expected}</code> but behind <code>${canon}</code> by <b>${behind}</b>%DUR%
<pre>${missing}</pre>→ §3c.2 merge-then-pull: <code>${fixhint}</code>"
    return
  fi
}

process_primary() {
  local path=$1 expected=$2 remote=$3
  assess_primary "$path" "$expected" "$remote"
  local sf="$STATE_DIR/$(sanitize "$path").state"
  local now; now=$(date +%s)
  local prev_sig="" first="" last_alert=0
  [ "$DRY" = 0 ] && [ -f "$sf" ] && IFS='|' read -r prev_sig first last_alert < "$sf"

  if [ "$ASSESS_STATUS" = "OK" ]; then
    if [ -n "$prev_sig" ] && [ "$prev_sig" != "ok" ]; then
      emit "🟢 <b>Primary resolved: $(basename "$path")</b>
back on <code>${expected}</code>, in sync with <code>${remote}/${expected}</code>"
    fi
    [ "$DRY" = 0 ] && echo "ok|${now}|${now}" > "$sf"
    return
  fi

  # NOCANON: surface once, but don't anchor a duration (transient/offline).
  if [ "$ASSESS_SIG" != "$prev_sig" ] || [ -z "$first" ]; then first=$now; last_alert=0; fi
  local age=$(( now - first )) dur durtext=""
  dur=$(human_duration "$age")
  case "$ASSESS_STATUS" in PARKED|STALE) durtext=" for <b>${dur}</b>" ;; esac
  local body=${ASSESS_BODY/\%DUR\%/$durtext}

  if [ "$ASSESS_SIG" != "$prev_sig" ] || [ $(( now - last_alert )) -ge "$RENAG" ]; then
    emit "$body"; last_alert=$now
  fi
  [ "$DRY" = 0 ] && echo "${ASSESS_SIG}|${first}|${last_alert}" > "$sf"
}

run_scan() {
  local spec path exp rem
  for spec in "${PRIMARIES[@]}"; do
    IFS='|' read -r path exp rem <<< "$spec"
    process_primary "$path" "$exp" "$rem"
  done
}

log "fleet-health starting (pid=$$, watch=$WATCH, dry=$DRY, fetch=$DO_FETCH)"
if [ "$WATCH" = 1 ]; then
  trap 'log "shutting down (pid=$$)"; exit 0' INT TERM
  while true; do run_scan; sleep "$POLL"; done
else
  run_scan
fi

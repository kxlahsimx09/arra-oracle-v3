#!/usr/bin/env bash
# staging-lock.sh — fleet mutex for the shared STAGING env (sinuw) that the
# live-tester journey scripts (A/B/C/D) drive. Only ONE agent may run against
# staging at a time — concurrent runs corrupt test results. Any agent that wants
# the env must acquire this lock first; Fleet Town visualizes the holder and lets
# the owner release it from the UI.
#
# State lives under ~/.fleet-town/locks/ (Fleet Town already owns ~/.fleet-town/):
#   <name>.json      — the holder record (present ⇒ locked)
#   <name>.disabled  — marker; present ⇒ lock DISABLED = behaves exactly like
#                      before any lock existed (acquire is a no-op success).
#
# Usage:
#   staging-lock.sh status   [--name staging] [--json]
#   staging-lock.sh acquire  --agent <oracle> [--name staging] [--campaign <c>] [--reason <r>]
#   staging-lock.sh release  [--agent <oracle>] [--name staging] [--force]
#   staging-lock.sh steal    --agent <oracle> [--name staging] [--campaign <c>] [--reason <r>]
#   staging-lock.sh disable  [--name staging]
#   staging-lock.sh enable   [--name staging]
#
# Exit codes (so caller scripts can branch deterministically):
#   0  success (acquired / released / free / disabled no-op)
#   2  usage error
#   3  acquire: HELD BY ANOTHER agent — caller asks owner, then `steal` or waits
#   4  release: caller is not the holder (pass --force to override)
#
# Owner: brew-ops. Source of truth: this file. Town UI: oracle-studio /town.

set -uo pipefail
SCRIPT_NAME=$(basename "$0")
die() { printf '\033[31m✗\033[0m %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
say() { printf '  %s\n' "$*"; }

CMD="${1:-}"; [ $# -gt 0 ] && shift
NAME="staging"; AGENT=""; CAMPAIGN=""; REASON=""; FORCE=""; AS_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)     NAME=${2:-};     shift 2 ;;
    --agent)    AGENT=${2:-};    shift 2 ;;
    --campaign) CAMPAIGN=${2:-}; shift 2 ;;
    --reason)   REASON=${2:-};   shift 2 ;;
    --force)    FORCE=1;         shift ;;
    --json)     AS_JSON=1;       shift ;;
    *)          die "unknown arg: $1" ;;
  esac
done

LOCK_DIR="$HOME/.fleet-town/locks"
LOCK_FILE="$LOCK_DIR/${NAME}.json"
DISABLED_FILE="$LOCK_DIR/${NAME}.disabled"
mkdir -p "$LOCK_DIR"

is_disabled() { [ -f "$DISABLED_FILE" ]; }

# Build the holder record. python3 (an established fleet dep) emits safe JSON and
# captures the caller's identity so Town can match it to a sprite (tmux_pane).
holder_json() {
  AGENT="$AGENT" CAMPAIGN="$CAMPAIGN" REASON="$REASON" NAME="$NAME" \
  PANE="${TMUX_PANE:-}" WT="$(pwd)" HOST="$(hostname)" PID="$$" python3 - <<'PY'
import os, json, time
print(json.dumps({
  "name": os.environ["NAME"], "locked": True,
  "holder": {
    "agent":    os.environ["AGENT"] or "unknown",
    "campaign": os.environ["CAMPAIGN"] or None,
    "reason":   os.environ["REASON"] or None,
    "tmux_pane": os.environ["PANE"] or None,
    "worktree": os.environ["WT"], "host": os.environ["HOST"],
    "pid": int(os.environ["PID"]),
    "acquired_at":    time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "acquired_epoch": int(time.time()),
  },
}, indent=2))
PY
}

# read_field <holder-key> — echo a field from the current lock (empty if free)
read_field() {
  [ -f "$LOCK_FILE" ] || return 0
  KEY="$1" python3 - "$LOCK_FILE" <<'PY'
import os, json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print((d.get("holder") or {}).get(os.environ["KEY"], "") if d.get("locked") else "")
PY
}

cmd_status() {
  if is_disabled; then
    [ -n "$AS_JSON" ] && printf '{"name":"%s","disabled":true,"locked":false}\n' "$NAME" \
      || say "lock '$NAME' is DISABLED — no locking (same as before the mechanism existed)"
    return 0
  fi
  if [ -f "$LOCK_FILE" ]; then
    if [ -n "$AS_JSON" ]; then cat "$LOCK_FILE"; else
      say "lock '$NAME' HELD by '$(read_field agent)' — campaign=$(read_field campaign) pane=$(read_field tmux_pane) since=$(read_field acquired_at)"
      say "reason: $(read_field reason)"
    fi
  else
    [ -n "$AS_JSON" ] && printf '{"name":"%s","disabled":false,"locked":false}\n' "$NAME" \
      || say "lock '$NAME' is FREE"
  fi
}

cmd_acquire() {
  [ -n "$AGENT" ] || die "acquire: missing --agent"
  if is_disabled; then ok "lock '$NAME' DISABLED — proceeding without lock (no-op)"; return 0; fi
  local json; json="$(holder_json)"
  # atomic O_EXCL create — only one concurrent caller wins
  if ( set -o noclobber; printf '%s\n' "$json" > "$LOCK_FILE" ) 2>/dev/null; then
    ok "acquired lock '$NAME' for '$AGENT'${CAMPAIGN:+ (campaign $CAMPAIGN)}"; return 0
  fi
  # already held — if it's this same pane, refresh idempotently
  if [ -n "${TMUX_PANE:-}" ] && [ "$(read_field tmux_pane)" = "$TMUX_PANE" ]; then
    printf '%s\n' "$json" > "$LOCK_FILE"
    ok "re-acquired (refreshed) lock '$NAME' — already held by this pane $TMUX_PANE"; return 0
  fi
  printf '\033[31m✗\033[0m %s: lock '\''%s'\'' is HELD BY ANOTHER agent:\n' "$SCRIPT_NAME" "$NAME" >&2
  cat "$LOCK_FILE" >&2
  printf '  → ask the owner before seizing. If approved: %s steal --agent %s --name %s\n' "$SCRIPT_NAME" "$AGENT" "$NAME" >&2
  exit 3
}

cmd_release() {
  if is_disabled; then ok "lock '$NAME' is disabled — nothing to release"; return 0; fi
  [ -f "$LOCK_FILE" ] || { say "lock '$NAME' already free"; return 0; }
  if [ -z "$FORCE" ]; then
    local cp ca; cp="$(read_field tmux_pane)"; ca="$(read_field agent)"
    if [ "${TMUX_PANE:-__nopane}" != "$cp" ] && [ "${AGENT:-__noagent}" != "$ca" ]; then
      printf '\033[31m✗\033[0m %s: not the holder ('\''%s'\'' / pane %s) — pass --force to override.\n' "$SCRIPT_NAME" "$ca" "$cp" >&2
      exit 4
    fi
  fi
  rm -- "$LOCK_FILE"; ok "released lock '$NAME'${FORCE:+ (forced)}"
}

cmd_steal() {
  [ -n "$AGENT" ] || die "steal: missing --agent"
  if is_disabled; then ok "lock '$NAME' disabled — nothing to steal (acquire is a no-op)"; return 0; fi
  local prev=""; [ -f "$LOCK_FILE" ] && prev="$(read_field agent) / pane $(read_field tmux_pane)"
  printf '%s\n' "$(holder_json)" > "$LOCK_FILE"
  ok "STOLE lock '$NAME' for '$AGENT'${prev:+ — evicted: $prev}"
}

cmd_disable() {
  : > "$DISABLED_FILE"
  [ -f "$LOCK_FILE" ] && rm -- "$LOCK_FILE"
  ok "lock '$NAME' DISABLED — behaves like before any lock existed (no locking)"
}

cmd_enable() {
  [ -f "$DISABLED_FILE" ] && rm -- "$DISABLED_FILE"
  ok "lock '$NAME' ENABLED — agents must acquire before using the env"
}

case "$CMD" in
  status)  cmd_status ;;
  acquire) cmd_acquire ;;
  release) cmd_release ;;
  steal)   cmd_steal ;;
  disable) cmd_disable ;;
  enable)  cmd_enable ;;
  -h|--help|"") sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: '$CMD' (status|acquire|release|steal|disable|enable)" ;;
esac

#!/usr/bin/env bash
# migration-lock.sh — fleet registry that RESERVES supabase migration version
# numbers at allocation time, so two parallel branches never pick the same 14-digit
# prefix (the recurring #836/#888 collision). Mirrors staging-lock.sh: same
# ~/.fleet-town/locks/ home, same DISABLED no-op mode, same holder record + exit
# codes — but it is a MULTI-SLOT registry (one file per reserved version) instead
# of a single mutex. `acquire` prints the next collision-free version on stdout;
# the agent names its migration <version>_<slug>.sql. The PreToolUse guard
# (.claude/hooks/guard-migrations.sh) blocks any new migration whose version the
# caller did not reserve — that hook is what makes this advisory lock enforced.
#
# State under ~/.fleet-town/locks/migrations/ :
#   <version>.json   — a reservation (holder record)
#   ../migrations.disabled — marker; present ⇒ DISABLED = acquire still prints a
#                      number but reserves nothing (behaves like before the lock).
#
# Usage:
#   migration-lock.sh acquire  --agent <a> [--campaign <c>] [--reason <r>] [--repo <p>]
#   migration-lock.sh check    --version <v> [--repo <p>]      # hook: held-by-you?
#   migration-lock.sh status | list [--json]
#   migration-lock.sh release  --version <v> [--agent <a>] [--force]
#   migration-lock.sh gc [--repo <p>]                          # reclaim merged/expired
#   migration-lock.sh steal    --version <v> --agent <a> [--reason <r>]
#   migration-lock.sh disable | enable
#
# Exit: 0 ok · 2 usage · 1 check:unreserved · 3 check:held-by-another · 4 release:not-holder
# Owner: brew-ops. Allocation source-of-truth: origin/main + this registry.
set -uo pipefail
SCRIPT_NAME=$(basename "$0")
die() { printf '\033[31m✗\033[0m %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*" >&2; }   # >&2: stdout stays clean for `acquire`
say() { printf '  %s\n' "$*" >&2; }

CMD="${1:-}"; [ $# -gt 0 ] && shift
AGENT=""; CAMPAIGN=""; REASON=""; VERSION=""; REPO=""; FORCE=""; AS_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)    AGENT=${2:-};    shift 2 ;;
    --campaign) CAMPAIGN=${2:-}; shift 2 ;;
    --reason)   REASON=${2:-};   shift 2 ;;
    --version)  VERSION=${2:-};  shift 2 ;;
    --repo)     REPO=${2:-};     shift 2 ;;
    --force)    FORCE=1;         shift ;;
    --json)     AS_JSON=1;       shift ;;
    *)          die "unknown arg: $1" ;;
  esac
done

LOCK_DIR="$HOME/.fleet-town/locks/migrations"
DISABLED_FILE="$HOME/.fleet-town/locks/migrations.disabled"
TTL_DAYS="${MIGLOCK_TTL_DAYS:-14}"
mkdir -p "$LOCK_DIR"
is_disabled() { [ -f "$DISABLED_FILE" ]; }

resolve_repo() {
  [ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO" ] || die "not in a git repo — pass --repo <path>"
}
this_worktree() { git -C "${REPO:-.}" rev-parse --show-toplevel 2>/dev/null || pwd; }

# highest 14-digit version among merged migrations on origin/main (best-effort fetch)
main_hwm() {
  git -C "$REPO" fetch -q origin main 2>/dev/null || true
  git -C "$REPO" ls-tree --name-only origin/main supabase/migrations/ 2>/dev/null \
    | sed -nE 's#.*/([0-9]{14})_.*#\1#p' | sort -n | tail -1
}
reserved_hwm() { ls "$LOCK_DIR"/*.json 2>/dev/null | sed -nE 's#.*/([0-9]{14})\.json#\1#p' | sort -n | tail -1; }

read_field() { # file key
  [ -f "$1" ] || return 0
  KEY="$2" python3 - "$1" <<'PY' 2>/dev/null || true
import os, json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print((d.get("holder") or {}).get(os.environ["KEY"], "") or "")
PY
}

holder_json() { # version
  AGENT="$AGENT" CAMPAIGN="$CAMPAIGN" REASON="$REASON" VER="$1" REPO="$REPO" \
  PANE="${TMUX_PANE:-}" WT="$(this_worktree)" HOST="$(hostname)" PID="$$" python3 - <<'PY'
import os, json, time
print(json.dumps({
  "version": os.environ["VER"], "reserved": True,
  "holder": {
    "agent": os.environ["AGENT"] or "unknown", "campaign": os.environ["CAMPAIGN"] or None,
    "reason": os.environ["REASON"] or None, "tmux_pane": os.environ["PANE"] or None,
    "worktree": os.environ["WT"], "repo": os.environ["REPO"], "host": os.environ["HOST"],
    "pid": int(os.environ["PID"]),
    "acquired_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "acquired_epoch": int(time.time()),
  },
}, indent=2))
PY
}

cmd_acquire() {
  [ -n "$AGENT" ] || die "acquire: missing --agent"
  resolve_repo
  local now m r next; now="$(date +%Y%m%d%H%M%S)"; m="$(main_hwm)"; r="$(reserved_hwm)"
  next="$now"
  [ -n "$m" ] && [ "$((m + 1))" -gt "$next" ] && next="$((m + 1))"
  [ -n "$r" ] && [ "$((r + 1))" -gt "$next" ] && next="$((r + 1))"
  if is_disabled; then
    say "lock DISABLED — number not reserved (collision guarantee OFF). Next free ≈ below."
    printf '%s\n' "$next"; return 0
  fi
  while :; do                                   # atomic O_EXCL — concurrent callers can't collide
    if ( set -o noclobber; printf '%s\n' "$(holder_json "$next")" > "$LOCK_DIR/$next.json" ) 2>/dev/null; then
      ok "reserved migration version $next for '$AGENT'${CAMPAIGN:+ (campaign $CAMPAIGN)}"
      say "→ name your file: ${next}_<slug>.sql"
      printf '%s\n' "$next"; return 0           # ONLY the version on stdout
    fi
    next="$((next + 1))"                         # lost the race — take the next slot
  done
}

cmd_check() { # hook contract: 0 held-by-you · 1 unreserved · 3 held-by-another
  [ -n "$VERSION" ] || die "check: missing --version"
  is_disabled && { echo "disabled"; return 0; }
  resolve_repo
  local f="$LOCK_DIR/$VERSION.json"
  [ -f "$f" ] || { echo "unreserved"; return 1; }
  if [ "$(read_field "$f" worktree)" = "$(this_worktree)" ]; then echo "held-by-you"; return 0
  else echo "held-by-other:$(read_field "$f" agent)"; return 3; fi
}

cmd_status() {
  if is_disabled; then
    [ -n "$AS_JSON" ] && echo '{"disabled":true,"reservations":[]}' || say "migration-lock is DISABLED — no reservations enforced"
    return 0
  fi
  local any=""
  if [ -n "$AS_JSON" ]; then
    printf '['; for f in "$LOCK_DIR"/*.json; do [ -e "$f" ] || continue; [ -n "$any" ] && printf ','; cat "$f"; any=1; done; printf ']\n'; return 0
  fi
  for f in $(ls "$LOCK_DIR"/*.json 2>/dev/null | sort); do
    any=1; local v; v="$(basename "$f" .json)"
    say "$v  agent=$(read_field "$f" agent)  campaign=$(read_field "$f" campaign)  reason=$(read_field "$f" reason)"
  done
  [ -n "$any" ] || say "no migration versions reserved (registry empty)"
}

cmd_release() {
  [ -n "$VERSION" ] || die "release: missing --version"
  local f="$LOCK_DIR/$VERSION.json"
  [ -f "$f" ] || { say "version $VERSION not reserved (already free)"; return 0; }
  if [ -z "$FORCE" ]; then
    resolve_repo
    local cw ca; cw="$(read_field "$f" worktree)"; ca="$(read_field "$f" agent)"
    if [ "$(this_worktree)" != "$cw" ] && [ "${AGENT:-_}" != "$ca" ]; then
      printf '\033[31m✗\033[0m %s: not the holder of %s (%s / %s) — pass --force.\n' "$SCRIPT_NAME" "$VERSION" "$ca" "$cw" >&2; exit 4
    fi
  fi
  rm -- "$f"; ok "released migration version $VERSION${FORCE:+ (forced)}"
}

cmd_gc() {
  resolve_repo
  git -C "$REPO" fetch -q origin main 2>/dev/null || true
  local merged reclaimed=0 now f v ep age
  merged="$(git -C "$REPO" ls-tree --name-only origin/main supabase/migrations/ 2>/dev/null | sed -nE 's#.*/([0-9]{14})_.*#\1#p')"
  now="$(date +%s)"
  for f in "$LOCK_DIR"/*.json; do
    [ -e "$f" ] || continue; v="$(basename "$f" .json)"
    if printf '%s\n' "$merged" | grep -qxF "$v"; then
      rm -- "$f"; ok "reclaimed $v — merged to origin/main"; reclaimed="$((reclaimed + 1))"; continue
    fi
    ep="$(read_field "$f" acquired_epoch)"; [ -n "$ep" ] || continue
    age="$(( (now - ep) / 86400 ))"
    if [ "$age" -ge "$TTL_DAYS" ]; then
      rm -- "$f"; ok "reclaimed $v — expired (${age}d ≥ ${TTL_DAYS}d TTL)"; reclaimed="$((reclaimed + 1))"
    fi
  done
  say "gc: reclaimed $reclaimed reservation(s)"
}

cmd_steal() {
  [ -n "$VERSION" ] && [ -n "$AGENT" ] || die "steal: need --version and --agent"
  resolve_repo
  local prev=""; [ -f "$LOCK_DIR/$VERSION.json" ] && prev="$(read_field "$LOCK_DIR/$VERSION.json" agent)"
  printf '%s\n' "$(holder_json "$VERSION")" > "$LOCK_DIR/$VERSION.json"
  ok "STOLE version $VERSION for '$AGENT'${prev:+ — evicted: $prev}"
}

cmd_disable() { : > "$DISABLED_FILE"; ok "migration-lock DISABLED — acquire still prints numbers, reserves nothing"; }
cmd_enable()  { [ -f "$DISABLED_FILE" ] && rm -- "$DISABLED_FILE"; ok "migration-lock ENABLED — agents must acquire before creating a migration"; }

case "$CMD" in
  acquire) cmd_acquire ;;
  check)   cmd_check ;;
  status|list) cmd_status ;;
  release) cmd_release ;;
  gc)      cmd_gc ;;
  steal)   cmd_steal ;;
  disable) cmd_disable ;;
  enable)  cmd_enable ;;
  -h|--help|"") sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: '$CMD' (acquire|check|status|list|release|gc|steal|disable|enable)" ;;
esac

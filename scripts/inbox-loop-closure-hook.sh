#!/usr/bin/env bash
# inbox-loop-closure-hook.sh — Agent CLI `Stop` hook (§11d enforcement)
#
# Problem it fixes: a dispatched oracle agent does the work but its session
# exits without (1) writing the reply envelope for a `needs_response: true`
# envelope and/or (2) archiving the inbound envelope per AGENTS.md §11d.
# A skill step alone does not stick — agents skip it. This hook turns the
# §11e Step 0.5 close-out into a hard, harness-level gate: the session
# CANNOT end while the loop is open.
#
# Mechanism: registered as a `Stop` hook in agent runtimes (Claude/Codex). On
# every stop it identifies the oracle (via the inbox-watcher's own
# session→oracle map), then blocks the stop (exit 2 + stderr) if the oracle
# still has an unhandled envelope, or archived a needs_response envelope with
# no reply.
#
# Self-gating: it engages ONLY for sessions the inbox-watcher spawned to
# handle an envelope (session-id reverse lookup). Every other session —
# interactive dev work, non-oracle panes — is a silent no-op.
#
# Fail-open: any unexpected error allows the stop. A hook must never wedge a
# session. The inbox-watcher T2 `failed_stuck` gate remains the backstop.
#
# Owner: brew-ops. See AGENTS.md §11l. Source of truth: this file in
# arra-oracle-v3/scripts/; deployed copy under runtime hooks dirs by
# install-inbox-loop-closure-hook.sh.

set -uo pipefail
trap 'exit 0' ERR   # fail-open: never block a session on a hook bug

INBOX_BASE=${INBOX_BASE:-$HOME/.arra-oracle-v2/ψ/inbox}
WATCHER_STATE=${INBOX_WATCHER_STATE:-$HOME/.cache/inbox-watcher}
HOOK_STATE=${INBOX_LOOP_HOOK_STATE:-$HOME/.cache/inbox-loop-closure}
MAX_BLOCKS=${INBOX_LOOP_MAX_BLOCKS:-3}
REPLY_WINDOW_HOURS=${INBOX_LOOP_REPLY_WINDOW_HOURS:-12}
ORACLE_API=${ORACLE_API:-http://localhost:47778/api}  # for §11g moot detection

allow() { exit 0; }                       # let the session stop
block() { printf '%s\n' "$1" >&2; exit 2; }  # exit 2 → runtime sees stderr, continues

mkdir -p "$HOOK_STATE" 2>/dev/null || true
# opportunistic GC of stale per-session block counters (>2 days old)
find "$HOOK_STATE" -name '*.blocks' -mtime +2 -delete 2>/dev/null || true

# --- read the Stop-hook payload from stdin -----------------------------------
payload=$(cat 2>/dev/null || true)
# Runtime payloads vary:
# - Claude hooks commonly include top-level `.session_id`
# - Codex rollout/session payloads use `.payload.id` (session UUID)
# Keep this tolerant and fail-open.
sid=$(printf '%s' "$payload" \
  | jq -r '.session_id // .payload.session_id // .payload.id // .id // empty' 2>/dev/null || true)
[ -z "$sid" ] && sid=${ARRA_SESSION_ID:-${SESSION_ID:-}}
[ -z "$sid" ] && allow

# --- identify the oracle this session belongs to -----------------------------
# Primary: the inbox-watcher writes session_id= into each per-envelope state
# file (~/.cache/inbox-watcher/state/<oracle>/<envelope>.state). Reverse-lookup
# that map. Only watcher-spawned inbox sessions match → only they are gated.
oracle=""
if [ -d "$WATCHER_STATE/state" ]; then
  hit=$(grep -rlF "session_id=$sid" "$WATCHER_STATE"/state/*/ 2>/dev/null | head -1 || true)
  [ -n "$hit" ] && oracle=$(basename "$(dirname "$hit")")
fi
# Fallback: the sessions/<oracle>/thread-<K>.session-id index.
if [ -z "$oracle" ] && [ -d "$WATCHER_STATE/sessions" ]; then
  for f in "$WATCHER_STATE"/sessions/*/*.session-id; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f" 2>/dev/null)" = "$sid" ]; then
      oracle=$(basename "$(dirname "$f")"); break
    fi
  done
fi
# Last resort: explicit env override (for future maw-injected wakes).
[ -z "$oracle" ] && oracle=${ARRA_ORACLE:-}

# Not a watcher-spawned oracle inbox session → nothing to enforce.
[ -z "$oracle" ] && allow
inbox_dir="$INBOX_BASE/for-$oracle"
[ -d "$inbox_dir" ] || allow

# --- frontmatter field reader (value of `field:` inside the first --- block) -
fm_field() {  # $1=file $2=field
  awk -v f="$2" '
    /^---[[:space:]]*$/ { c++; next }
    c==1 && $0 ~ "^"f":" {
      sub("^"f":[[:space:]]*",""); sub("[[:space:]]*#.*","")
      gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit
    }
    c>=2 { exit }
  ' "$1" 2>/dev/null
}

# --- per-session scoping (thread #214 wake_key + thread #238 owner) -----------
# With concurrent sessions of one oracle (the #181 parallel-sessions-same-role
# pattern), for-{oracle}/ holds envelopes for SIBLING sessions' campaigns too.
# Gate THIS session only on the envelopes it actually owns; leave a sibling's
# envelopes in place (archiving them would corrupt the sibling's audit trail).
# Two scoping schemes, by oracle kind:
#
#   • Non-orchestrator (thread #214): a session owns exactly ONE campaign, keyed
#     by wake_key (parent_thread || thread) — the same key §11f and the
#     inbox-watcher use. Derive my wake_key(s) from the watcher state files that
#     name my session_id; gate only on envelopes whose wake_key matches.
#
#   • Orchestrator (thread #238): the multi-campaign hub. ONE session legitimately
#     spans MANY wake_keys, so wake_key scoping would blind it to its own other
#     campaigns. But under #181 there can be CONCURRENT orchestrator sessions
#     (e.g. wt-20/21/22 on 2026-05-26), each owning a DIFFERENT subset of
#     campaigns — so the old whole-dir gate false-blocked each session on its
#     siblings' envelopes (re-hit ~5× during campaign #228/#234/#237). Scope by
#     §151 OWNERSHIP instead: an envelope is mine iff the inbox-watcher recorded
#     THIS session's worktree as the owner of its campaign
#     (sessions/orchestrator/thread-<wake_key>.owner == my worktree). This is the
#     same "scope the gate the way the work is scoped" move as §214, using the
#     per-session discriminator (worktree) that fits a multi-campaign hub — where
#     §214's single-wake_key key does not.
#
# Undeterminable scope (cache evicted / unknown sid / no owner record / no
# wake_key) → fall back to gating (whole-dir): over-blocking is safe — the §11i
# T2 failed_stuck watcher gate is the backstop — whereas silently skipping a
# genuinely-owned envelope would re-open the #140 silent-stall class.
my_wt=$(printf '%s' "$payload" | jq -r '.cwd // .payload.cwd // .payload.session_meta.cwd // empty' 2>/dev/null || true)
[ -z "$my_wt" ] && my_wt=$PWD
my_wt=${my_wt%/}

scope_campaign=0
scope_owner=0
my_wake_keys=""
if [ "$oracle" = "orchestrator" ]; then
  [ -n "$my_wt" ] && [ -d "$WATCHER_STATE/sessions/$oracle" ] && scope_owner=1
elif [ -d "$WATCHER_STATE/state/$oracle" ]; then
  my_wake_keys=$(grep -lF "session_id=$sid" "$WATCHER_STATE/state/$oracle"/*.state 2>/dev/null \
    | while IFS= read -r sf; do
        wk=$(sed -n 's/^wake_key=//p' "$sf" 2>/dev/null | head -1 || true)
        [ -n "$wk" ] || wk=$(sed -n 's/^thread_id=//p' "$sf" 2>/dev/null | head -1 || true)
        [ -n "$wk" ] && printf '%s\n' "$wk"
      done | sort -u) || true
  [ -n "$my_wake_keys" ] && scope_campaign=1
fi

# envelope wake_key = parent_thread (campaign) else thread
env_wake_key() {  # $1=file
  local pt
  pt=$(fm_field "$1" parent_thread)
  if [ -n "$pt" ]; then printf '%s' "$pt"; return 0; fi
  fm_field "$1" thread
}

# §151 owner worktree recorded by the inbox-watcher for a campaign (orchestrator
# owner-scoping). Empty when no .owner file exists for the wake_key.
owner_wt() {  # $1=wake_key → prints owner worktree path or empty
  local f="$WATCHER_STATE/sessions/$oracle/thread-$1.owner"
  [ -f "$f" ] && head -1 "$f"
}

# is this envelope THIS session's to close? (true when no scoping is active)
in_scope() {  # $1=file → 0 = in scope (gate), 1 = sibling-owned (skip)
  local wk owner
  if [ "$scope_owner" = 1 ]; then          # thread #238: orchestrator by §151 owner
    wk=$(env_wake_key "$1")
    [ -n "$wk" ] || return 0               # unattributable wake_key → gate (safe)
    owner=$(owner_wt "$wk")
    [ -n "$owner" ] || return 0            # no owner record → gate (safe)
    [ "${owner%/}" = "$my_wt" ] && return 0 || return 1
  fi
  [ "$scope_campaign" = 1 ] || return 0    # thread #214: non-orchestrator by wake_key
  wk=$(env_wake_key "$1")
  [ -n "$wk" ] || return 0   # no thread/parent_thread → don't skip (be safe)
  if printf '%s\n' "$my_wake_keys" | grep -qxF "$wk"; then return 0; else return 1; fi
}

# --- Check 1: inbound envelopes still unhandled in the inbox root ------------
unhandled=""
for f in "$inbox_dir"/*.md; do
  [ -e "$f" ] || continue
  bn=$(basename "$f")
  [ "$bn" = ".gitkeep" ] && continue
  in_scope "$f" || continue          # thread #214: skip sibling-campaign envelopes
  from=$(fm_field "$f" from)
  thr=$(fm_field "$f" thread)
  nr=$(fm_field "$f" needs_response)
  po=$(fm_field "$f" parent_oracle)
  reply_to=${po:-$from}
  unhandled+="  • $bn"$'\n'"      from=$from thread=${thr:-none} needs_response=${nr:-false} → reply to for-${reply_to}/"$'\n'
done

# --- thread status via the Oracle API (mirrors inbox-watcher's thread_status)
# Echoes 'closed'|'active'|'pending'|'' — empty means the API is unreachable
# or the thread is unknown.
thread_status() {  # $1=thread id — always exits 0 (failure = empty output)
  [ -n "${1:-}" ] || { echo ""; return 0; }
  curl -sf -m 3 "$ORACLE_API/thread/$1" 2>/dev/null \
    | jq -r '.thread.status // empty' 2>/dev/null || true
}

# --- does a reply envelope from THIS oracle for thread <thr> exist? ----------
# The §11c close-out artifact is a reply envelope on disk in the requestor's
# inbox (root, or already archived under handled/). The check verifies that
# ARTIFACT — it does not trust a frontmatter field, because an agent can stamp
# handled_by_inbox without ever writing the file (thread #159).
reply_envelope_exists() {  # $1=reply-target oracle  $2=thread id
  local d="$INBOX_BASE/for-$1" g
  [ -d "$d" ] || return 1
  for g in "$d"/*_from-"$oracle"_thread-"$2"_reply.md \
           "$d"/handled/*/*_from-"$oracle"_thread-"$2"_reply.md; do
    [ -e "$g" ] && return 0
  done
  return 1
}

# --- Check 2: needs_response envelopes archived WITHOUT a reply --------------
# §11c close-out for a needs_response:true envelope is a REPLY ENVELOPE in the
# requestor's inbox — that is the artifact the requestor's watcher routes on to
# wake them. This check verifies that artifact EXISTS; it deliberately does NOT
# trust the handled_by_inbox / handled_note frontmatter fields.
#
# Why (thread #159, recurrence of the #140 class): next-architect finished a
# resumed-session dispatch, archived the consult envelope with a bogus
# handled_by_inbox (the inbound envelope's own basename, not a reply path) plus
# a verbose handled_note, but never wrote the reply envelope. The old check
# skipped on mere field-presence, so the Stop hook passed and the orchestrator
# was never woken. Verifying the artifact closes that hole for fresh and
# --resume sessions alike. A missing reply is a gap UNLESS the thread is closed
# (§11g moot — no reply owed). Scoped to a recent mtime window so old pre-hook
# debt is not re-litigated by unrelated sessions.
reply_gap=""
cutoff=$(( $(date +%s) - REPLY_WINDOW_HOURS * 3600 ))
for f in "$inbox_dir"/handled/*/*.md; do
  [ -e "$f" ] || continue
  in_scope "$f" || continue          # thread #214: only THIS session's campaign
  mt=$(stat -f %m "$f" 2>/dev/null || echo 0)
  [ "$mt" -lt "$cutoff" ] && continue
  [ "$(fm_field "$f" needs_response)" = "true" ] || continue
  from=$(fm_field "$f" from); thr=$(fm_field "$f" thread)
  po=$(fm_field "$f" parent_oracle); reply_to=${po:-$from}
  # Loop closed: the reply envelope artifact exists.
  reply_envelope_exists "$reply_to" "$thr" && continue
  # No reply envelope — a closed thread is §11g moot (no reply owed).
  st=$(thread_status "$thr")
  [ "$st" = "closed" ] && continue
  # API unreachable (empty status): degrade to the pre-fix moot escape so a
  # transient outage cannot wedge a session on a legitimately-mooted envelope.
  [ -z "$st" ] && [ -n "$(fm_field "$f" handled_note)" ] && continue
  reply_gap+="  • handled/$(basename "$(dirname "$f")")/$(basename "$f")"$'\n'"      from=$from thread=${thr:-none} status=${st:-unreachable} → reply to for-${reply_to}/"$'\n'
done

# --- clean? let the session stop ---------------------------------------------
if [ -z "$unhandled" ] && [ -z "$reply_gap" ]; then
  rm -f "$HOOK_STATE/$sid.blocks" 2>/dev/null || true
  allow
fi

# --- circuit breaker: don't loop forever on a genuinely stuck agent ----------
bc_file="$HOOK_STATE/$sid.blocks"
bc=$(( $(cat "$bc_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$bc" >"$bc_file"

if [ "$bc" -gt "$MAX_BLOCKS" ]; then
  rm -f "$bc_file" 2>/dev/null || true
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s [%s] loop-closure gave up after %s blocks\nunhandled:\n%sreply_gap:\n%s\n' \
    "$ts" "$oracle" "$MAX_BLOCKS" "$unhandled" "$reply_gap" \
    >>"$HOOK_STATE/escalations.log" 2>/dev/null || true
  # Make the give-up VISIBLE: notify the orchestrator (a silent give-up would
  # re-introduce the exact bug this hook exists to kill).
  thr=$(printf '%s' "$unhandled$reply_gap" | grep -oE 'thread=[0-9]+' | head -1 | cut -d= -f2)
  notify="$INBOX_BASE/for-orchestrator/$(date +%Y-%m-%d_%H-%M)_from-${oracle}${thr:+_thread-$thr}_notify.md"
  if [ -d "$INBOX_BASE/for-orchestrator" ]; then
    { printf -- '---\nfrom: %s\nto: orchestrator\ntype: notify\n' "$oracle"
      [ -n "$thr" ] && printf 'thread: %s\n' "$thr"
      printf 'subject: loop-closure FAILED — %s could not close its inbox after %s attempts\n' "$oracle" "$MAX_BLOCKS"
      printf 'needs_response: false\npriority: high\ncreated: %s\n---\n\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
      printf 'The inbox-loop-closure Stop hook blocked %s %s times but the loop is still open.\n\n' "$oracle" "$MAX_BLOCKS"
      printf 'Unhandled inbound envelopes:\n%s\nneeds_response envelopes archived without a reply:\n%s\n' "${unhandled:-  (none)}" "${reply_gap:-  (none)}"
      printf '\nManual close-out required. See ~/.cache/inbox-loop-closure/escalations.log\n'
    } >"$notify" 2>/dev/null || true
  fi
  printf '⚠️  inbox loop-closure: %s still open after %s attempts — allowing stop, orchestrator notified.\n' \
    "$oracle" "$MAX_BLOCKS" >&2
  allow
fi

# --- build the block message -------------------------------------------------
msg="🔁 INBOX LOOP NOT CLOSED — you are oracle \"$oracle\" and cannot end this session yet (attempt $bc/$MAX_BLOCKS).

Per AGENTS.md §11c–§11d and the brew-ops SKILL \"Inbox protocol\" (envelope-first,
archive-second), every inbound envelope you handled must be fully closed out
BEFORE your session ends.

If this gate is unexpected: the envelope(s) below were routed into THIS session
by the inbox-watcher for a campaign you own (AGENTS.md §11l / §151 sticky
thread→session ownership). As of thread #214 this gate is campaign-scoped — it
lists ONLY envelopes whose wake_key (parent_thread || thread) matches the
campaign this session was spawned to handle, so a sibling same-oracle session's
envelopes are NOT shown here and are NOT yours to close. Handle the one(s)
listed and the gate clears. (The orchestrator hub scopes this by §151 campaign
OWNERSHIP instead of wake_key — thread #238 — so you see only campaigns whose
owner worktree is this session's; a sibling orchestrator session's campaigns are
not shown and are not yours to close.)"

if [ -n "$unhandled" ]; then
  msg+="

── Unhandled inbound envelope(s) still in for-$oracle/ ──
$unhandled
For EACH, before stopping:
  1. arra_thread_read its thread; if status is closed → §11g moot path
     (archive with handled_note, no reply).
  2. If needs_response=true → post your result to that thread (arra_thread)
     AND write a reply envelope to the for-{reply-target}/ shown above
     (filename: YYYY-MM-DD_HH-MM_from-${oracle}_thread-<id>_reply.md).
  3. Archive the inbound envelope (P-001 — move, never delete):
       cd \"$INBOX_BASE/for-$oracle/\"
       month=\$(date +%Y-%m); mkdir -p handled/\$month
       # first append handled_at / handled_by_thread / handled_by_inbox
       #   to the envelope frontmatter, THEN:
       git mv <envelope>.md handled/\$month/"
fi

if [ -n "$reply_gap" ]; then
  msg+="

── needs_response envelope(s) archived WITHOUT a reply ──
$reply_gap
A thread reply with no reply ENVELOPE is a silent stall — the requestor's
watcher never wakes. For EACH: post your result to the thread, then WRITE the
reply envelope FILE to the for-{reply-target}/ shown above (filename:
YYYY-MM-DD_HH-MM_from-${oracle}_thread-<id>_reply.md), and append
handled_by_inbox: <that-reply-envelope-path> to the archived envelope's
frontmatter. This gate verifies the reply envelope file actually exists —
stamping handled_by_inbox without writing the file will NOT clear it."
fi

msg+="

Do this now, then finish. (This gate is the inbox-loop-closure Stop hook —
AGENTS.md §11l. It clears automatically once the loop is closed.)"

block "$msg"

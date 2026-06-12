#!/usr/bin/env bash
# fts-reindex.sh — periodic STEP-1 (SQLite + FTS5) reindex of the Oracle vault.
#
# Closes the "no watcher / no cron → fresh ψ/ files invisible until a manual
# reindex" gap (thread #15; learning 2026-06-12_gotcha-the-oracle-vault-has-no-
# watcher-and-no-cr). Runs ONLY STEP 1 (`bun src/indexer/cli.ts`). It NEVER runs
# the ~84-min vector STEP 2 (`index-model.ts`) — that stays manual/on-demand.
#
# Scheduled by launchd `com.soulbrews.fts-reindex` (StartInterval, default 15m).
# Safe to run by hand:  ARRA=… ORACLE_REPO_ROOT=… bash scripts/fts-reindex.sh [--force]
#
# Guards (all chosen for thread #15 §2):
#   1. atomic mkdir lock — never two STEP-1 instances at once (stale >20m reaped);
#   2. defer if a vector build is running — STEP 1 rewrites oracle.db rows; WAL
#      (busy_timeout=5000) avoids "database is locked" but NOT a consistent
#      snapshot for STEP 2's row-by-row pagination, so it is NOT provably safe
#      alongside STEP 2. Deferring a 15-min tick during an infrequent 84-min
#      build is free;
#   3. change-detection (vault git signature) — skip the indexer, and its
#      per-run 38MB db backup + JSON/CSV export, when the vault is unchanged.
#
# Loud-failure contract (thread #15 §3): every tick writes a heartbeat to
# $LAST_RUN (mtime = last attempt, body = status); a non-zero indexer exit logs
# FAIL + the output tail and exits non-zero. A *dead* job is detectable by a
# stale $LAST_RUN mtime (> ~2× interval) or `launchctl list | grep fts-reindex`.

set -uo pipefail   # deliberately NOT -e: we log failures loudly, never die silently

ARRA="${ARRA:-$HOME/Code/github.com/Soul-Brews-Studio/arra-oracle-v3}"
VAULT_ROOT="${ORACLE_REPO_ROOT:-$HOME/Code/github.com/kxlahsimx09/mb_agent_oracle_memory}"
STATE="$HOME/.cache/fts-reindex"
LOG="$STATE/fts-reindex.log"
LOCK="$STATE/lock.d"
LAST_RUN="$STATE/last-run"      # touched every tick → liveness heartbeat
SIG_FILE="$STATE/indexed-sig"   # vault signature captured at last successful index
KEEP_BACKUPS=20                 # newest N indexer auto-backups/exports to retain
mkdir -p "$STATE"

ts()  { date +%Y-%m-%dT%H:%M:%S%z; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >> "$LOG"; }
beat(){ printf '[%s] %s\n' "$(ts)" "$*" > "$LAST_RUN"; }

force=0; [ "${1:-}" = "--force" ] && force=1

# --- Guard 1: single STEP-1 at a time (atomic) -------------------------------
if ! mkdir "$LOCK" 2>/dev/null; then
  if find "$LOCK" -maxdepth 0 -mmin +20 2>/dev/null | grep -q .; then
    log "WARN reaping stale lock (>20m)"; rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || { log "SKIP lock busy after reap"; beat "SKIP lock"; exit 0; }
  else
    log "SKIP another fts-reindex holds the lock"; beat "SKIP lock"; exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# --- Guard 2: never overlap a running vector build ---------------------------
if pgrep -f "index-model.ts" >/dev/null 2>&1; then
  log "SKIP vector build (index-model.ts) running — deferring to next tick"
  beat "SKIP vector-build"; exit 0
fi

# --- Guard 3: change-detection (skip indexer + its backup when unchanged) -----
sig="$(git -C "$VAULT_ROOT" rev-parse HEAD 2>/dev/null)|$(git -C "$VAULT_ROOT" status --porcelain 2>/dev/null | cksum | tr -s ' ' '-')"
prev="$(cat "$SIG_FILE" 2>/dev/null || echo none)"
if [ "$force" -eq 0 ] && [ "$sig" = "$prev" ]; then
  log "SKIP vault unchanged"; beat "SKIP unchanged"; exit 0
fi

# --- Run STEP 1 ---------------------------------------------------------------
cd "$ARRA" || { log "FAIL cannot cd $ARRA"; beat "FAIL cd"; exit 1; }
export ORACLE_REPO_ROOT="$VAULT_ROOT"
log "START step1 (ARRA=$ARRA ORACLE_REPO_ROOT=$VAULT_ROOT force=$force)"
out="$(bun src/indexer/cli.ts 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -E 'Discovered|Indexed [0-9]|Smart delete|complete|[Ee]rror|[Ff]ailed' >> "$LOG"

if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'Indexing complete'; then
  n="$(printf '%s\n' "$out" | grep -oE 'Indexed [0-9]+ documents' | tail -1)"
  printf '%s' "$sig" > "$SIG_FILE"
  log "OK  step1 — ${n:-indexed}"; beat "OK ${n:-indexed}"
  # prune the indexer's per-run auto-backups/exports → keep newest $KEEP_BACKUPS
  for pat in 'oracle.db.backup-*' 'oracle.db.export-*.json' 'oracle.db.export-*.csv'; do
    ls -t "$HOME/.arra-oracle-v2"/$pat 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r f; do rm -- "$f"; done
  done
else
  log "FAIL step1 indexer rc=$rc — output tail:"; printf '%s\n' "$out" | tail -25 >> "$LOG"
  beat "FAIL rc=$rc"; exit 1
fi
log "done"

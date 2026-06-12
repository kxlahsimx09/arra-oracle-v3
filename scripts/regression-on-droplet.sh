#!/usr/bin/env bash
# regression-on-droplet.sh — run the mobiz integration-test regression suite on a
# remote Docker host (the DO regression droplet) over SSH, reusing mobiz's own
# integration-tests scripts unchanged. The droplet does the heavy lifting (docker
# build + run); this control-side script syncs, drives, and collects results.
#
# This is the droplet analogue of the local `regression-then-investigate.sh`
# build+run core. It exists because the watcher host has no usable Docker daemon
# (learning 2026-06-12_fleet-infra-temp-mb-regression-droplet). Pair with
# provision-regression-droplet.sh (one-time host setup).
#
# Usage:
#   REGRESSION_HOST=root@178.128.93.199 bash scripts/regression-on-droplet.sh
#   TESTS="test-deposit-flow.sh test-deposit-cancel.sh" bash scripts/regression-on-droplet.sh   # subset
#
# Env:
#   REGRESSION_HOST   ssh target (default root@178.128.93.199)
#   BRANCH            mobiz branch to sync+test (default main)
#   BANK_BOT_BRANCH   bank-bot branch (default main)
#   TESTS             space-separated test list (default = docs/regression-suite.txt)
#   FAIL_FAST         1 = stop on first failure (default), 0 = run all
#   PER_TEST_TIMEOUT  seconds per test (default 1800)
#   SKIP_BUILD        1 = skip down/up --build (reuse the running stack)
# Exit: 0 = all passed, 1 = a failure / infra problem.

set -uo pipefail

HOST="${REGRESSION_HOST:-root@178.128.93.199}"
BRANCH="${BRANCH:-main}"
BANK_BOT_BRANCH="${BANK_BOT_BRANCH:-main}"
FAIL_FAST="${FAIL_FAST:-1}"
PER_TEST_TIMEOUT="${PER_TEST_TIMEOUT:-1800}"
SKIP_BUILD="${SKIP_BUILD:-0}"
MOBIZ="/root/Code/github.com/kokarat/mobiz-payment-gateway"
IT="$MOBIZ/integration-tests"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR_REMOTE="/root/regression-runs/$RUN_ID"
LOG_DIR_LOCAL="$HOME/.cache/w2-watcher/regression-droplet/$RUN_ID"
mkdir -p "$LOG_DIR_LOCAL"

ssh_opts=(-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes)
d()   { ssh "${ssh_opts[@]}" "$HOST" "$@"; }
log() { printf '\033[0;36m[droplet-reg]\033[0m %s\n' "$*"; }
abort(){ printf '\033[0;31mABORT:\033[0m %s\n' "$*" >&2; exit 1; }

log "host=$HOST  run=$RUN_ID  branch=$BRANCH  fail_fast=$FAIL_FAST"
d 'echo ok' >/dev/null 2>&1 || abort "cannot SSH to $HOST"
d "mkdir -p $RUN_DIR_REMOTE"

# ── 1. Sync repos (ff-only; operator contract: main, clean, ff-able) ──────────
log "syncing mobiz + bank-bot to origin/$BRANCH …"
d bash -se <<REMOTE 2>"$LOG_DIR_LOCAL/sync.err" || abort "repo sync failed (see $LOG_DIR_LOCAL/sync.err) — droplet checkout dirty/non-ff?"
set -e
git -C "$MOBIZ" fetch origin "$BRANCH" --quiet && git -C "$MOBIZ" merge --ff-only "origin/$BRANCH" --quiet
git -C "$MOBIZ/bank-bot" fetch origin "$BANK_BOT_BRANCH" --quiet && git -C "$MOBIZ/bank-bot" merge --ff-only "origin/$BANK_BOT_BRANCH" --quiet
REMOTE
log "  mobiz @ $(d "git -C $MOBIZ rev-parse --short HEAD")  bank-bot @ $(d "git -C $MOBIZ/bank-bot rev-parse --short HEAD")"

# ── 2. Fresh stack (state hygiene — mirrors regression-then-investigate.sh) ────
if [ "$SKIP_BUILD" != 1 ]; then
  log "docker compose down -v && up -d --build (fresh containers + deps)…"
  d "cd $IT && docker compose down -v >>$RUN_DIR_REMOTE/infra.log 2>&1 || true"
  if ! d "cd $IT && docker compose up -d --build >>$RUN_DIR_REMOTE/infra.log 2>&1"; then
    d "tail -40 $RUN_DIR_REMOTE/infra.log" > "$LOG_DIR_LOCAL/infra.log" 2>&1
    abort "docker compose up --build failed (see $LOG_DIR_LOCAL/infra.log)"
  fi
else
  log "SKIP_BUILD=1 — reusing the running stack"
fi

# ── 3. Wait for core services healthy ─────────────────────────────────────────
log "waiting for backend + mock-bank healthy…"
ready=0
for _ in $(seq 1 60); do
  hs="$(d "cd $IT && docker compose ps --format '{{.Service}}={{.Health}}' 2>/dev/null" 2>/dev/null)"
  if grep -q "backend=healthy" <<<"$hs" && grep -q "mock-bank=healthy" <<<"$hs"; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || { d "cd $IT && docker compose ps" > "$LOG_DIR_LOCAL/ps.txt" 2>&1; abort "services not healthy in time (see $LOG_DIR_LOCAL/ps.txt)"; }
log "  stack healthy"

# ── 4. Resolve suite + run each test ──────────────────────────────────────────
SUITE=()
if [ -n "${TESTS:-}" ]; then
  read -r -a SUITE <<<"$TESTS"
else
  while IFS= read -r line; do [ -n "$line" ] && SUITE+=("$line"); done \
    < <(d "grep -vE '^[[:space:]]*#|^[[:space:]]*\$' $MOBIZ/docs/regression-suite.txt")
fi
TOTAL=${#SUITE[@]}
log "running $TOTAL test(s) (TEST_RUNNER_MODE=1, ${PER_TEST_TIMEOUT}s each)…"
PASSED=(); FAILED=(); SUITE_START=$(date +%s)
for test in "${SUITE[@]}"; do
  [ -z "$test" ] && continue
  printf '  → %-48s ' "$test"
  t0=$(date +%s)
  if d "cd $MOBIZ && TEST_RUNNER_MODE=1 DOCKER_MODE=true SKIP_INFRA=true timeout $PER_TEST_TIMEOUT bash integration-tests/$test > $RUN_DIR_REMOTE/$test.log 2>&1"; then
    printf '\033[0;32mPASS\033[0m (%ss)\n' "$(( $(date +%s) - t0 ))"; PASSED+=("$test")
  else
    rc=$?
    printf '\033[0;31mFAIL\033[0m (rc=%s, %ss)\n' "$rc" "$(( $(date +%s) - t0 ))"; FAILED+=("$test")
    d "cat $RUN_DIR_REMOTE/$test.log" > "$LOG_DIR_LOCAL/$test.log" 2>&1   # pull the failing log
    [ "$FAIL_FAST" = 1 ] && { log "fail-fast: stopping (set FAIL_FAST=0 to run all)"; break; }
  fi
done

# ── 5. Summary ────────────────────────────────────────────────────────────────
SUITE_MIN=$(( ($(date +%s) - SUITE_START) / 60 ))
echo "────────────────────────────────────────────"
log "RESULT: ${#PASSED[@]}/$TOTAL passed, ${#FAILED[@]} failed (${SUITE_MIN}m). remote logs: $HOST:$RUN_DIR_REMOTE"
if [ ${#FAILED[@]} -gt 0 ]; then
  printf '  failed: %s\n' "${FAILED[*]}"
  log "failing logs pulled to: $LOG_DIR_LOCAL"
  exit 1
fi
log "ALL PASS ✅"

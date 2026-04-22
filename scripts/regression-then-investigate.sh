#!/usr/bin/env bash
# regression-then-investigate.sh — chain after tester W1 wake
#
# Called by w2-watcher.sh in background after `maw wake tester` returns exit 0.
#
# Flow:
#   1. Gate — verify tester W1 passed (`Newly-broken = 0` in docs/test-index.md)
#   2. Start infra — spawn run-integration-test.sh, wait for "Environment Ready"
#   3. Run every test in docs/regression-suite.txt sequentially (30-min safety
#      timeout per test; each test has its own MAX_WAIT internally)
#   4. Teardown infra
#   5. If all pass → Telegram curl direct to ampay_test_alert_bot chat
#      If any fail → maw wake tester --fresh "investigate <logs>" → tester
#                    reads failure logs, classifies, reports via
#                    mcp__tester-telegram__telegram_send (plain Thai)
#
# Usage (normally invoked by watcher):
#   bash scripts/regression-then-investigate.sh
#
# Env overrides:
#   MOBIZ        — path to mobiz repo (default: ghq default location)
#   SUITE        — path to regression-suite.txt (default: $MOBIZ/docs/regression-suite.txt)
#   LOG_ROOT     — where per-run log dirs go (default: ~/.cache/w2-watcher/regression)
#   PER_TEST_TIMEOUT — safety-net timeout per test (default: 30m)
#   INFRA_READY_TIMEOUT — how long to wait for "Environment Ready" (default: 300s)

set -u

# Detach stdin from any inherited tty at script entry. Without this, deep
# children (docker compose exec → mongosh) can receive SIGTTIN when they
# probe /dev/tty in a background process group → process stops with state T
# → whole chain hangs. Even if the caller forgot `</dev/null`, this line
# makes the script self-isolating. Safe side effect: no interactive prompts
# inside the script can succeed — which is the right behavior for
# unattended runs anyway.
exec </dev/null

MOBIZ=${MOBIZ:-$HOME/Code/github.com/kokarat/mobiz-payment-gateway}
SUITE=${SUITE:-$MOBIZ/docs/regression-suite.txt}
LOG_ROOT=${LOG_ROOT:-$HOME/.cache/w2-watcher/regression}
PER_TEST_TIMEOUT=${PER_TEST_TIMEOUT:-30m}
INFRA_READY_TIMEOUT=${INFRA_READY_TIMEOUT:-300}

RUN_ID=$(date '+%Y%m%d-%H%M%S')
RUN_DIR=$LOG_ROOT/$RUN_ID
mkdir -p "$RUN_DIR"

# RUN_LABEL is "Regression" by default, flips to "Single-test" when SINGLE_TEST
# env is set. Used in Telegram output so the operator can tell quickly which
# flavor of run they're seeing.
RUN_LABEL="Regression"

# ── Single-instance lock ───────────────────────────────────────────────────
# Two concurrent regression runs would race on the shared docker stack
# (mongodb, redis, backend :3099, bank-bot containers) → non-deterministic
# test results. Watcher's MIN_GAP (2h) usually prevents it, but a long
# regression (> 2h) + newly-settled commits, OR a manual spawn during a
# watcher-triggered run, can cause overlap. Skip + Telegram if another
# instance is alive.
LOCK=$LOG_ROOT/.regression.lock
mkdir -p "$(dirname "$LOCK")"
if [ -f "$LOCK" ]; then
  OTHER_PID=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$OTHER_PID" ] && ps -p "$OTHER_PID" > /dev/null 2>&1; then
    # Telegram creds read opportunistically (send_tg isn't defined yet)
    TOKEN=$(jq -r --arg p "$MOBIZ" '.projects[$p].mcpServers["tester-telegram"].env.TELEGRAM_BOT_TOKEN // empty' "$HOME/.claude.json" 2>/dev/null)
    CHAT=$(jq -r --arg p "$MOBIZ" '.projects[$p].mcpServers["tester-telegram"].env.TELEGRAM_DEFAULT_CHAT_ID // empty' "$HOME/.claude.json" 2>/dev/null)
    if [ -n "$TOKEN" ] && [ -n "$CHAT" ]; then
      curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=🟡 <b>Regression skipped</b> (run <code>${RUN_ID}</code>)
Another regression instance is still running (pid=<code>${OTHER_PID}</code>). Skipping to avoid concurrent docker-stack races.

ถ้ามันค้าง → <code>kill -9 ${OTHER_PID} && rm ${LOCK}</code> แล้ว re-run" \
        -o /dev/null 2>/dev/null
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: another regression running (pid=$OTHER_PID), lock=$LOCK" >&2
    exit 0
  fi
  # Stale lock (pid dead) — reclaim
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] reclaiming stale lock (pid=$OTHER_PID no longer alive)" >&2
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# ── Telegram creds — read from ~/.claude.json (same source as the MCP) ─────
TOKEN=$(jq -r --arg p "$MOBIZ" '.projects[$p].mcpServers["tester-telegram"].env.TELEGRAM_BOT_TOKEN // empty' "$HOME/.claude.json" 2>/dev/null)
CHAT=$(jq -r --arg p "$MOBIZ" '.projects[$p].mcpServers["tester-telegram"].env.TELEGRAM_DEFAULT_CHAT_ID // empty' "$HOME/.claude.json" 2>/dev/null)

log() {
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" | tee -a "$RUN_DIR/runner.log"
}

send_tg() {
  # usage: send_tg "<html text>"
  local text="$1"
  if [ -z "$TOKEN" ] || [ -z "$CHAT" ]; then
    log "WARN: telegram creds not found in ~/.claude.json — skipping send"
    return
  fi
  curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" \
    -o /dev/null 2>>"$RUN_DIR/runner.log" \
    || log "WARN: telegram send failed"
}

log "regression-then-investigate started"
log "  MOBIZ=$MOBIZ"
log "  SUITE=$SUITE"
log "  RUN_DIR=$RUN_DIR"

# ── Step 0: W1 gate ────────────────────────────────────────────────────────
TEST_INDEX="$MOBIZ/docs/test-index.md"
if [ ! -f "$TEST_INDEX" ]; then
  log "ABORT: $TEST_INDEX not found — tester W1 may not have run or MOBIZ path is wrong"
  send_tg "🟡 <b>Regression skipped</b> — <code>docs/test-index.md</code> not found. Tester W1 didn't land its output, or MOBIZ path is wrong. Run <code>$RUN_DIR/runner.log</code>"
  exit 1
fi

NEWLY_BROKEN=$(grep -E '^\- Newly-broken since prior baseline: ' "$TEST_INDEX" | head -1 | grep -oE '[0-9]+' | head -1)
if [ -z "$NEWLY_BROKEN" ]; then
  log "ABORT: could not parse Newly-broken count from $TEST_INDEX"
  send_tg "🟡 <b>Regression skipped</b> — could not parse <code>Newly-broken</code> count from tester W1's <code>docs/test-index.md</code>. Format may have drifted. Run <code>$RUN_DIR</code>"
  exit 1
fi

if [ "$NEWLY_BROKEN" -ne 0 ]; then
  log "SKIP: W1 reports Newly-broken=$NEWLY_BROKEN — regression would run against stale tests"
  send_tg "🟡 <b>Regression skipped</b> (run <code>${RUN_ID}</code>)
Tester W1 reports <b>Newly-broken = ${NEWLY_BROKEN}</b> — ต้องเคลียร์ STALE list ก่อน regression จะรันได้แบบมีความหมาย

ดู <code>docs/test-index.md</code> + <code>${RUN_DIR}/runner.log</code>"
  exit 0
fi

log "W1 gate passed (Newly-broken=0)"

# ── Step 1: Build test list ────────────────────────────────────────────────
# Two modes:
#   - Default: read the whole regression-suite.txt
#   - SINGLE_TEST=<basename>.sh: run just that one test (same infra + Telegram
#     + investigation flow — useful for iterating on a single failing case
#     without rebuilding + running the full suite)
if [ -n "${SINGLE_TEST:-}" ]; then
  # SINGLE_TEST overrides the suite. Accept with or without the leading
  # 'integration-tests/' path prefix for convenience.
  SINGLE_TEST="${SINGLE_TEST#integration-tests/}"
  if [ ! -f "$MOBIZ/integration-tests/$SINGLE_TEST" ]; then
    log "ABORT: SINGLE_TEST=$SINGLE_TEST not found in $MOBIZ/integration-tests/"
    send_tg "🟡 <b>Single-test run skipped</b> (run <code>${RUN_ID}</code>)
<code>SINGLE_TEST=${SINGLE_TEST}</code> not found in <code>integration-tests/</code>"
    exit 1
  fi
  TESTS=("$SINGLE_TEST")
  RUN_LABEL="Single-test"
  log "SINGLE_TEST mode: $SINGLE_TEST"
else
  if [ ! -f "$SUITE" ]; then
    log "ABORT: suite file not found: $SUITE"
    send_tg "🟡 <b>Regression skipped</b> — <code>docs/regression-suite.txt</code> missing in mobiz"
    exit 1
  fi

  TESTS=()
  while IFS= read -r line; do
    line="${line%%#*}"            # strip trailing comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [ -n "$line" ] && TESTS+=("$line")
  done < "$SUITE"

  log "Parsed ${#TESTS[@]} tests from $SUITE"

  if [ "${#TESTS[@]}" -eq 0 ]; then
    log "ABORT: no tests parsed from $SUITE"
    send_tg "🟡 <b>Regression skipped</b> — zero tests parsed from <code>$SUITE</code>"
    exit 1
  fi

  # Verify every referenced test file exists
  MISSING=()
  for t in "${TESTS[@]}"; do
    [ -f "$MOBIZ/integration-tests/$t" ] || MISSING+=("$t")
  done
  if [ ${#MISSING[@]} -gt 0 ]; then
    log "ABORT: ${#MISSING[@]} test files missing from integration-tests/:"
    printf '  - %s\n' "${MISSING[@]}" | tee -a "$RUN_DIR/runner.log"
    send_tg "🟡 <b>Regression skipped</b> — ${#MISSING[@]} test file(s) listed in <code>regression-suite.txt</code> but missing from <code>integration-tests/</code>: $(printf '%s, ' "${MISSING[@]}")"
    exit 1
  fi
fi

TOTAL=${#TESTS[@]}

# ── Step 2: Sync $MOBIZ with origin/main ──────────────────────────────────
# Contract with the operator (agreed 2026-04-21): $MOBIZ is kept on main,
# clean, and ff-able at all times — any dev work happens in separate
# worktrees. So a forced fetch + pull --ff-only is always safe here and
# guarantees docker build uses the exact commit that triggered the watcher
# (not stale user-local state).
#
# If the pull fails (wrong branch, dirty tree, diverged history), the
# contract was violated — abort + Telegram so the operator sees it and fixes.
cd "$MOBIZ" || { log "ABORT: cannot cd into $MOBIZ"; exit 1; }

log "Syncing \$MOBIZ with origin/main..."
# Race-safe sync: `git pull --ff-only origin main` reads .git/FETCH_HEAD,
# which is shared across worktrees. When pg-writer wake fires its claude
# in another worktree concurrently and that claude does any `git fetch`,
# FETCH_HEAD gets contaminated and our pull errors with
# "Cannot fast-forward to multiple branches" (observed live 2026-04-22
# 01:27 — pg-writer wake fired 5s after our regression spawn, race blew up
# the pull). Fix: use explicit ref `merge --ff-only origin/main` which
# reads the remote-tracking ref directly, no FETCH_HEAD dependency.
if ! git fetch origin main --quiet 2>>"$RUN_DIR/runner.log"; then
  log "ABORT: git fetch origin main failed"
  send_tg "🟡 <b>Regression skipped</b> (run <code>${RUN_ID}</code>)
<code>git fetch origin main</code> failed in <code>\$MOBIZ</code>. Network? Ref issue?

ดู <code>$RUN_DIR/runner.log</code>"
  exit 1
fi
if ! git merge --ff-only origin/main --quiet 2>>"$RUN_DIR/runner.log"; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  DIRTY=$(git status --porcelain 2>/dev/null | head -1)
  log "ABORT: git merge --ff-only origin/main failed (branch=$BRANCH, dirty=${DIRTY:+yes})"
  send_tg "🟡 <b>Regression skipped</b> (run <code>${RUN_ID}</code>)
<code>git merge --ff-only origin/main</code> failed in <code>\$MOBIZ</code>.
branch: <code>$BRANCH</code> | dirty: <code>${DIRTY:+yes}${DIRTY:-no}</code>

Operator contract: <code>\$MOBIZ</code> must stay on <code>main</code>, clean, ff-able. ทำ dev อื่นใน worktree. แก้ state ก่อน re-run

ดู <code>$RUN_DIR/runner.log</code>"
  exit 1
fi
log "  \$MOBIZ at $(git rev-parse --short HEAD) ($(git log -1 --format='%s' | head -c 60))"

# ── Step 2.5: Sync $MOBIZ/bank-bot with origin/main ────────────────────────
# bank-bot/ is a gitignored subfolder in mobiz but is actually a separate
# git clone of kokarat/bank-bot (same remote as the standalone repo).
# docker-compose's bank-bot + bank-bot-ktb services build their image from
# this folder — so its freshness matters equally to $MOBIZ itself.
#
# Operator contract (agreed 2026-04-21): same as $MOBIZ — main, clean,
# ff-able. Dev work happens in separate worktrees.
BANK_BOT="$MOBIZ/bank-bot"
if [ ! -d "$BANK_BOT/.git" ]; then
  log "ABORT: $BANK_BOT is not a git repo (expected a kokarat/bank-bot clone)"
  send_tg "🟡 <b>Regression skipped</b> (run <code>${RUN_ID}</code>)
<code>\$MOBIZ/bank-bot</code> is not a git checkout. Expected a clone of <code>kokarat/bank-bot</code>.

ดู <code>$RUN_DIR/runner.log</code>"
  exit 1
fi
cd "$BANK_BOT" || { log "ABORT: cannot cd into $BANK_BOT"; exit 1; }
log "Syncing \$BANK_BOT with origin/main..."
if ! git fetch origin main --quiet 2>>"$RUN_DIR/runner.log"; then
  log "ABORT: git fetch origin main failed in bank-bot"
  send_tg "🟡 <b>Regression skipped</b> (run <code>${RUN_ID}</code>)
<code>git fetch origin main</code> failed in <code>\$MOBIZ/bank-bot</code>. Network? Remote?

ดู <code>$RUN_DIR/runner.log</code>"
  exit 1
fi
if ! git merge --ff-only origin/main --quiet 2>>"$RUN_DIR/runner.log"; then
  BB_BRANCH=$(git branch --show-current 2>/dev/null)
  BB_DIRTY=$(git status --porcelain 2>/dev/null | head -1)
  log "ABORT: bank-bot merge --ff-only failed (branch=$BB_BRANCH, dirty=${BB_DIRTY:+yes})"
  send_tg "🟡 <b>Regression skipped</b> (run <code>${RUN_ID}</code>)
<code>git merge --ff-only origin/main</code> failed in <code>\$MOBIZ/bank-bot</code>.
branch: <code>$BB_BRANCH</code> | dirty: <code>${BB_DIRTY:+yes}${BB_DIRTY:-no}</code>

Operator contract: <code>\$MOBIZ/bank-bot</code> must stay on <code>main</code>, clean, ff-able. ทำ dev อื่นใน worktree. แก้ state ก่อน re-run

ดู <code>$RUN_DIR/runner.log</code>"
  exit 1
fi
log "  \$BANK_BOT at $(git rev-parse --short HEAD) ($(git log -1 --format='%s' | head -c 60))"

# Return cwd to $MOBIZ for subsequent docker compose + test invocations
cd "$MOBIZ"

# ── Step 2a: Rebuild images (backend + mock-bank + bank-bot) against HEAD ──
# User's setup is DOCKER_MODE (persistent containers for backend, bank-bot,
# bank-bot-ktb, mock-bank). Images must be rebuilt when source changes,
# otherwise tests run against stale code = misleading green/red.
#
# Rebuild all four relevant images every run. Docker layer cache keeps this
# fast when nothing relevant changed (~5-10s), slow on cold/first-run
# (~2-5min).
#
# mock-bank MUST be in the list — it is not "mostly static JS". It carries
# test-critical routing logic (e.g. resolveKTBBiznextAccount cross-bank
# guard from mobiz commit 1ad0712). Regression 20260421-165340 failed
# because mock-bank was skipped here and the container ran stale code,
# routing SCB statements to the KTB bot.

INFRA_LOG="$RUN_DIR/infra.log"
# up -d --build --no-deps so that containers whose image actually changed
# get recreated in the same step. A plain `build` leaves old containers
# running against new images, which was the root cause of regression
# 20260421-165340 for mock-bank. --no-deps keeps mongodb/redis untouched.
log "Rebuilding + recreating backend + mock-bank + bank-bot + bank-bot-ktb (docker layer cache will short-circuit if no changes)..."
BUILD_START=$(date +%s)
if ! docker compose -f integration-tests/docker-compose.yml up -d --build --no-deps \
    backend mock-bank bank-bot bank-bot-ktb >> "$INFRA_LOG" 2>&1; then
  log "ABORT: docker compose up --build failed — see $INFRA_LOG"
  send_tg "🔴 <b>Regression aborted</b> (run <code>${RUN_ID}</code>)
<code>docker compose up --build</code> failed. Source error or build-time failure — ไม่ได้รัน test เลย

ดู <code>${INFRA_LOG}</code>"
  exit 1
fi
BUILD_ELAPSED=$(($(date +%s) - BUILD_START))
log "  build done (${BUILD_ELAPSED}s)"

# ── Step 2b: Start infrastructure ──────────────────────────────────────────
# DOCKER_MODE=true — setup-infra.sh skips native go build + mock-bank native
#                   startup; waits for existing containers instead.
# SKIP_INFRA=true  — setup-infra.sh skips `docker compose up -d`
#                   AND infra_cleanup skips `docker compose down -v` — so our
#                   teardown (SIGTERM → trap → infra_cleanup) will NOT
#                   destroy the user's persistent stack.
log "Starting infrastructure (DOCKER_MODE=true SKIP_INFRA=true — respects user's persistent containers)..."
DOCKER_MODE=true SKIP_INFRA=true \
  bash integration-tests/run-integration-test.sh >> "$INFRA_LOG" 2>&1 &
INFRA_PID=$!
log "  run-integration-test.sh pid=$INFRA_PID — waiting up to ${INFRA_READY_TIMEOUT}s for ready marker"

READY=false
for _ in $(seq 1 "$INFRA_READY_TIMEOUT"); do
  if grep -q "Integration Test Environment Ready" "$INFRA_LOG" 2>/dev/null; then
    READY=true
    break
  fi
  if ! ps -p "$INFRA_PID" > /dev/null 2>&1; then
    log "  infra process died before ready signal"
    break
  fi
  sleep 1
done

if [ "$READY" != true ]; then
  log "ABORT: infrastructure failed to come up within ${INFRA_READY_TIMEOUT}s"
  # Polite: SIGTERM only. The spawned script's EXIT trap runs infra_cleanup
  # which respects SKIP_INFRA=true → leaves user's docker stack alone.
  kill "$INFRA_PID" 2>/dev/null
  send_tg "🔴 <b>Regression aborted</b> (run <code>${RUN_ID}</code>)
Infrastructure failed to start within ${INFRA_READY_TIMEOUT}s.
Backend/mock-bank container may be unhealthy — check <code>docker ps</code> + <code>${INFRA_LOG}</code>"
  exit 1
fi

log "Infrastructure ready"

# ── Step 3: Run tests sequentially ─────────────────────────────────────────
declare -a PASSED=()
declare -a FAILED=()
SUITE_START=$(date +%s)

# TEST_RUNNER_MODE=1 signals to each test.sh that it's running headless/
# automated (not interactive). Two effects that matter for the runner:
#   1. Native bank-bot spawns (e.g. collision-dual) use HEADLESS=true instead
#      of the default HEADLESS=false — keeps browser windows from popping up
#      during unattended regression runs.
#   2. Post-success hooks `exit 0` instead of trapping INT + `wait` forever,
#      so each test.sh terminates cleanly and the runner moves to the next.
# See integration-tests/test-deposit-collision*.sh, test-*-fifo*.sh etc.
export TEST_RUNNER_MODE=1

# Fail-fast mode (default): stop the suite on the first failure and investigate
# that one immediately. The operator can fix + re-run the suite rather than
# having noise from downstream failures caused by the same upstream bug.
#
# Override by setting FAIL_FAST=0 to run every test regardless (useful for a
# final "is the whole suite green?" check after fixes land).
FAIL_FAST=${FAIL_FAST:-1}

REMAINING=()
for idx in "${!TESTS[@]}"; do
  test="${TESTS[$idx]}"
  test_log="$RUN_DIR/$test.log"
  t_start=$(date +%s)
  log "▶ $test"
  if timeout "$PER_TEST_TIMEOUT" bash "integration-tests/$test" > "$test_log" 2>&1; then
    t_elapsed=$(($(date +%s) - t_start))
    log "  ✅ $test (${t_elapsed}s)"
    PASSED+=("$test")
  else
    rc=$?
    t_elapsed=$(($(date +%s) - t_start))
    log "  ❌ $test (exit=$rc, ${t_elapsed}s)"
    FAILED+=("$test|$rc|$t_elapsed")
    if [ "$FAIL_FAST" = "1" ]; then
      # Capture everything that didn't run so the Telegram / investigation
      # prompt can mention it. Index + 1 is the next unrun test.
      # Use bash C-style loop instead of `seq $((idx+1)) $((TOTAL-1))`:
      # on macOS (BSD seq), `seq 1 0` prints `1 0` descending — when the
      # failing test is the last (or only) one, that triggers a bogus
      # iteration that reads TESTS[TOTAL] → `set -u` unbound variable abort.
      # The C-style form cleanly skips when start >= TOTAL.
      for (( j = idx + 1; j < TOTAL; j++ )); do
        REMAINING+=("${TESTS[$j]}")
      done
      log "  fail-fast STOP (${#REMAINING[@]} tests not run; investigation will focus on this single failure)"
      break
    fi
  fi
done

SUITE_ELAPSED=$(($(date +%s) - SUITE_START))
SUITE_MIN=$((SUITE_ELAPSED / 60))

# ── Step 4: Teardown ───────────────────────────────────────────────────────
# SIGTERM the spawned run-integration-test.sh. Its EXIT trap runs infra_cleanup,
# which with DOCKER_MODE=true skips native process kill and with SKIP_INFRA=true
# skips `docker compose down -v`. So the user's persistent container stack
# remains running after this script exits.
#
# We do NOT call `run-integration-test.sh --cleanup` here — that path hardcodes
# `docker compose down -v` and would destroy the stack regardless of flags.
log "Tearing down infrastructure (SIGTERM; respects SKIP_INFRA so stack survives)..."
kill "$INFRA_PID" 2>/dev/null
sleep 2

# ── Step 5: Report ─────────────────────────────────────────────────────────
PASS_COUNT=${#PASSED[@]}
FAIL_COUNT=${#FAILED[@]}

if [ "$FAIL_COUNT" -eq 0 ]; then
  log "ALL PASS (${PASS_COUNT}/${TOTAL}, ${SUITE_MIN}m)"
  if [ "$RUN_LABEL" = "Single-test" ]; then
    PASS_BODY="<code>${TESTS[0]}</code> ผ่าน ไม่เจอ regression"
  else
    PASS_BODY="ตรวจครบทุก test ใน <code>docs/regression-suite.txt</code> — ไม่เจอ regression"
  fi
  send_tg "✅ <b>${RUN_LABEL} ${RUN_ID}</b> — ${PASS_COUNT}/${TOTAL} passed (${SUITE_MIN}m)

${PASS_BODY}

Log: <code>${RUN_DIR}</code>"
  exit 0
fi

# ── Extract the single failing test (fail-fast mode: always exactly 1) ─────
# In non-fail-fast mode (FAIL_FAST=0), FAILED[] may have multiple entries.
# Investigation prompt below handles both via the FAIL_LIST loop, but the
# single-fail path is the default and Telegram wording reflects it.
FIRST_FAIL_ENTRY="${FAILED[0]}"
IFS='|' read -r FIRST_FAIL_NAME FIRST_FAIL_RC FIRST_FAIL_SEC <<< "$FIRST_FAIL_ENTRY"
REMAINING_COUNT=${#REMAINING[@]}

log "FAIL-FAST stop: ${FIRST_FAIL_NAME} (passed ${PASS_COUNT} before, ${REMAINING_COUNT} not run, elapsed ${SUITE_MIN}m)"

# Build fail summary (supports multi-fail when FAIL_FAST=0)
FAIL_LIST=""
FAIL_SHORT=""
for entry in "${FAILED[@]}"; do
  IFS='|' read -r tname rc tsec <<< "$entry"
  FAIL_LIST="${FAIL_LIST}- ${tname} (exit=${rc}, ${tsec}s) — log: ${RUN_DIR}/${tname}.log
"
  FAIL_SHORT="${FAIL_SHORT}• ${tname}
"
done

REMAINING_SHORT=""
if [ "$REMAINING_COUNT" -gt 0 ]; then
  for r in "${REMAINING[@]}"; do REMAINING_SHORT="${REMAINING_SHORT}• ${r}
"; done
fi

# ── Step 6: Spawn investigation wake ───────────────────────────────────────
# Fail-fast mode = investigate ONE test. Non-fail-fast = multiple.
if [ "$FAIL_COUNT" -eq 1 ]; then
  INVESTIGATE_PROMPT="regression หยุดที่ test ตัวแรกที่ fail (fail-fast mode). ก่อนหน้านี้ผ่านไปแล้ว ${PASS_COUNT} tests ใน ${SUITE_MIN} นาที. อีก ${REMAINING_COUNT} tests ยังไม่ได้รัน (รอ fix + re-run).

Test ที่ fail: <code>${FIRST_FAIL_NAME}</code> (exit=${FIRST_FAIL_RC}, ${FIRST_FAIL_SEC}s)
Log หลักที่ต้องอ่าน: ${RUN_DIR}/${FIRST_FAIL_NAME}.log
Runner log: ${RUN_DIR}/runner.log
Infra log (docker + setup): ${RUN_DIR}/infra.log
Test script: integration-tests/${FIRST_FAIL_NAME}

Investigate ด้วย tester discipline:
  1. อ่าน ${FIRST_FAIL_NAME}.log — หา first error / assertion fail / non-200 / trap exit
  2. อ่าน test script integration-tests/${FIRST_FAIL_NAME} — เข้าใจว่ามัน assert อะไร, ทำ setup อะไร
  3. อ่าน production code ที่ test เรียก (controllers/services/routes ที่เกี่ยว) ณ HEAD
  4. Classify + report

Classify เป็น 1 ใน 4 ประเภท:
  1. code bug — production code เพิ่งเปลี่ยนและ break expected behavior → ระบุ commit/file:line
  2. test invalid — test เอง stale/wrong-assumption → ระบุว่าต้องแก้ assertion อะไร
  3. flaky — transient (timing/race/env) → reproduce ไม่ stable
  4. infra — docker/mock-bank/backend crash → ไม่ใช่ test issue

ส่ง summary ผ่าน mcp__tester-telegram__telegram_send เป็นภาษาไทยง่ายๆ:
- หัวข้อ: '🔴 Regression ${RUN_ID} — fail ที่ ${FIRST_FAIL_NAME}'
- ประเภทปัญหา + ปัญหา 1-2 ประโยค + ต้องแก้ที่ไหน (ระบุ file:line ถ้าได้)
- ถ้าเป็น flaky/infra: แนะนำว่า re-run อย่างเดียวพอไหม หรือต้อง investigate เพิ่ม

**ห้ามแก้ code/test** — แค่ investigate + report. Human จะ fix หลังเห็น Telegram แล้ว re-run regression"
else
  # FAIL_FAST=0 path — multi-test investigation (same as before)
  INVESTIGATE_PROMPT="regression รันจบแล้ว (FAIL_FAST=0) เจอ ${FAIL_COUNT} test fail จาก ${TOTAL} ใน ${SUITE_MIN} นาที. อ่าน log ใน ${RUN_DIR}/ ของทุก test ที่ fail (รายการด้านล่าง), investigate ทีละตัวด้วย tester discipline (อ่าน test script + production code ที่ test เรียก + log output), แล้วส่ง summary ไป mcp__tester-telegram__telegram_send เป็นภาษาไทยง่ายๆ.

สำหรับแต่ละ test ที่ fail ให้ classify เป็น 1 ใน 4 ประเภท:
  1. code bug — production code เพิ่งเปลี่ยนและ break expected behavior → ระบุ commit/file:line
  2. test invalid — test เอง stale/wrong-assumption → ระบุว่าต้องแก้ assertion อะไร
  3. flaky — transient (timing/race/env) → reproduce ไม่ stable
  4. infra — docker/mock-bank/backend crash → ไม่ใช่ test issue

Format Telegram summary (ส่งครั้งเดียว, ไม่เกิน 3000 chars):
- หัวข้อ: '🔴 Regression ${RUN_ID} — ${FAIL_COUNT}/${TOTAL} failed'
- ต่อ test: ชื่อ + classification + ปัญหา 1 ประโยค + ต้องแก้ที่ไหน (ระบุ file:line ถ้าได้)
- **ห้ามแก้ code/test** — แค่ investigate + report

Tests ที่ fail:
${FAIL_LIST}

Infra log: ${RUN_DIR}/infra.log
Runner log: ${RUN_DIR}/runner.log
Per-test logs: ${RUN_DIR}/<test-name>.log"
fi  # end fail-fast vs multi-fail branch

# maw wake's send-keys path truncates long multi-line prompts (Thai text +
# HTML tags + ~600+ bytes → maw's "DONE" end-marker leaks into the prompt,
# zsh gets stuck on an unclosed quote, claude never starts). Workaround:
# write the full prompt to a file in the run-dir, and pass a short pointer
# as the wake prompt. The wake shell can handle 1-line ASCII trivially.
PROMPT_FILE="$RUN_DIR/investigation-prompt.md"
printf '%s\n' "$INVESTIGATE_PROMPT" > "$PROMPT_FILE"
WAKE_POINTER="อ่าน $PROMPT_FILE ให้จบก่อน — นั่นคือ task ของคุณ. ทำตามคำสั่งในไฟล์ investigate + report ผ่าน mcp__tester-telegram__telegram_send ห้ามแก้ code/test."

# ── Primary notification (ALWAYS send, before spawning investigation) ─────
# The investigation wake can fail silently (Anthropic API overload, claude
# CLI crash in -p mode, maw wake succeeds but pasted command breaks). maw
# wake exits 0 as soon as it send-keys into the tmux pane — it does NOT
# wait for claude to finish. So "maw wake exit 0" ≠ "user got Telegram".
#
# Fix: send the primary fail notification via direct curl BEFORE spawning
# the investigation wake. Investigation is a nice-to-have depth — if it
# runs, the user gets a 2nd detailed Telegram; if it dies silently, the
# user still has this primary one and can re-run investigation manually.
#
# Observed live 2026-04-21 18:46 — API Error overloaded_error killed the
# investigation claude immediately, user got silent failure for 30+ min.
if [ "$FAIL_COUNT" -eq 1 ]; then
  send_tg "🔴 <b>${RUN_LABEL} ${RUN_ID}</b> — fail-fast stop at <code>${FIRST_FAIL_NAME}</code>

exit=${FIRST_FAIL_RC}, ${FIRST_FAIL_SEC}s. Passed ${PASS_COUNT}/${TOTAL} before this. ${REMAINING_COUNT} tests not run (fail-fast).
Elapsed ${SUITE_MIN}m.

Log: <code>${RUN_DIR}/${FIRST_FAIL_NAME}.log</code>

🔎 Investigation wake spawning — detailed classification follows if pg-tester API OK. ถ้า Telegram นี้ค้างไม่มี detail ต่อใน 5-10 min = investigation ล้ม, ต้อง investigate manual"
else
  send_tg "🔴 <b>${RUN_LABEL} ${RUN_ID}</b> — ${FAIL_COUNT}/${TOTAL} failed

Elapsed ${SUITE_MIN}m.

<b>Failed:</b>
${FAIL_SHORT}
🔎 Investigation wake spawning — per-test detail follows if pg-tester API OK"
fi

log "Spawning tester investigation wake (prompt in $PROMPT_FILE)..."
if maw wake pg-tester --fresh "$WAKE_POINTER" >> "$RUN_DIR/runner.log" 2>&1; then
  log "Investigation wake spawned — pg-tester MAY send detailed Telegram (best-effort; depends on API availability)"
else
  log "FAIL: maw wake pg-tester returned non-zero (user already has primary Telegram above; no extra fallback needed)"
fi

exit 1

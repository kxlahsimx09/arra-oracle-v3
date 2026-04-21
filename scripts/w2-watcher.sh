#!/usr/bin/env bash
# w2-watcher.sh — watch mobiz + bank-bot for new commits, trigger W2 (and W9
# chained immediately after) with debounce.
#
# Philosophy: W2 should fire *when there is work to do*, not on a dumb cron.
# When commits do arrive they tend to burst (analysis 2026-04-19: mobiz 54%,
# bank-bot 39% of commits land within 30 min of a prior one), so we wait for
# the burst to settle before triggering — otherwise W2 would fire 3-5 times
# in 30 min on the same cluster.
#
# Design (derived from 14-day commit-pattern analysis):
#   - POLL_INTERVAL (5 min)    — check for new commits on origin/main
#   - SETTLE_WINDOW (30 min)   — quiet period after the last new commit;
#                                 we only fire once the repo is quiet for
#                                 this long, so bursts get batched
#   - MIN_GAP (2 hr)           — floor between consecutive W2 runs on the
#                                 same repo, even if new commits keep landing
#
# W9 chaining (added 2026-04-21):
#   - W9 spec mandates "parallel to W2 on the daily cron" but no separate cron
#     infra exists yet (P2 follow-up flagged 2026-04-19 brew-ops audit). Same
#     wake handles both: claude reads the W2 spec, runs it to completion (incl.
#     Telegram), then reads the W9 spec and runs it. Mostly no-op for bank-bot
#     today (1 flow doc) but mobiz (6 flows) will see real work.
#   - W9 has its own Step 8.0/8.A/8.B detect→amend gate (added 2026-04-20 in
#     mb_agent_oracle_memory commit 0357769/0bdfdc3) so successive cycles will
#     extend the open W9 PR rather than stacking new ones — same shape as the
#     fix we landed for W2 the same week.
#
# Usage:
#   bash w2-watcher.sh              # foreground (tail -f style logs to stdout)
#   bash w2-watcher.sh &             # background
#   nohup bash w2-watcher.sh > ~/w2-watcher.log 2>&1 &   # persist past shell exit
#   bash w2-watcher.sh status        # show state per repo, whether W2 is primed
#   bash w2-watcher.sh stop          # kill a running watcher (by pid file)
#
# Override defaults from shell:
#   POLL_INTERVAL=600 SETTLE_WINDOW=900 MIN_GAP=3600 bash w2-watcher.sh

set -u

POLL_INTERVAL=${POLL_INTERVAL:-300}     # 5 min
SETTLE_WINDOW=${SETTLE_WINDOW:-1800}    # 30 min
MIN_GAP=${MIN_GAP:-7200}                # 2 hr

# Authors whose commits should NOT trigger W2. Matched (extended regex)
# against each commit's "author-name|author-email" line, so either field
# hitting the pattern is enough. We only care about commits from *other*
# contributors — our own pushes are not work we need to summarize.
IGNORE_AUTHORS=${IGNORE_AUTHORS:-'kxlahsimx09|amadeusmarsexpress'}

STATE_DIR=${STATE_DIR:-$HOME/.cache/w2-watcher}
PID_FILE=$STATE_DIR/watcher.pid
LOG_FILE=${LOG_FILE:-$STATE_DIR/watcher.log}
mkdir -p "$STATE_DIR"

# role → (repo_path, step_name_for_prompt)
declare -A REPOS=(
  ["pg-writer"]="$HOME/Code/github.com/kokarat/mobiz-payment-gateway"
  ["bot-writer"]="$HOME/Code/github.com/kokarat/bank-bot"
)
declare -A STEP_NAMES=(
  ["pg-writer"]="8b"   # mobiz W2 has Step 8b for Telegram
  ["bot-writer"]="6b"  # bank-bot W2 has Step 6b for Telegram (fewer steps)
)

log() {
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*"
}

cleanup() {
  log "shutting down (pid=$$)"
  rm -f "$PID_FILE"
  exit 0
}

# ── subcommands ────────────────────────────────────────────────────────────

cmd_status() {
  echo "w2-watcher state"
  echo "  state dir: $STATE_DIR"
  echo "  log:       $LOG_FILE"
  echo ""
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    if ps -p "$pid" > /dev/null 2>&1; then
      echo "  watcher:   running (pid=$pid)"
    else
      echo "  watcher:   stale pid file (pid=$pid not alive)"
    fi
  else
    echo "  watcher:   not running"
  fi
  echo ""
  for role in "${!REPOS[@]}"; do
    repo=${REPOS[$role]}
    state_file=$STATE_DIR/$role.state
    echo "── $role ──"
    if [ -f "$state_file" ]; then
      source "$state_file"
      now=$(date +%s)
      echo "    last_seen:      ${last_seen:0:12}"
      if [ "${last_new:-0}" -gt 0 ]; then
        age=$((now - last_new))
        settle_left=$((SETTLE_WINDOW - age))
        if [ $settle_left -gt 0 ]; then
          echo "    settling:       $((age/60)) min since last new commit ($((settle_left/60)) min left of settle window)"
        else
          echo "    settled:        new commits ready to trigger"
        fi
      else
        echo "    pending:        nothing new since last run"
      fi
      if [ "${last_run:-0}" -gt 0 ]; then
        gap=$((now - last_run))
        gap_left=$((MIN_GAP - gap))
        if [ $gap_left -gt 0 ]; then
          echo "    min_gap block:  $((gap/60)) min since last run ($((gap_left/60)) min left of min_gap)"
        else
          echo "    min_gap clear:  last run was $((gap/60)) min ago"
        fi
      else
        echo "    first run:      never triggered yet"
      fi
    else
      echo "    (uninitialized — run the watcher once to seed)"
    fi

    # W9 chain status — query GitHub for the current open W9 PR (if any).
    # This is what claude inside the wake will check via Step 8.0 detect →
    # 8.A (amend) if non-empty / 8.B (new) if empty. See workflow-9-track-flows.md.
    repo_slug=$(echo "$repo" | sed 's|.*/github\.com/||')
    if command -v gh > /dev/null 2>&1; then
      w9_pr=$(gh pr list --repo "$repo_slug" --search "head:docs/flow-track- state:open" --author "@me" --json number,headRefName,title,createdAt --jq '.[0]' 2>/dev/null)
      if [ -n "$w9_pr" ] && [ "$w9_pr" != "null" ]; then
        pr_num=$(jq -r .number <<< "$w9_pr" 2>/dev/null)
        pr_branch=$(jq -r .headRefName <<< "$w9_pr" 2>/dev/null)
        pr_age_iso=$(jq -r .createdAt <<< "$w9_pr" 2>/dev/null)
        echo "    W9 PR open:     #$pr_num ($pr_branch, opened $pr_age_iso)"
        echo "                    → next wake takes 8.A amend path on the W9 portion"
      else
        echo "    W9 PR:          none open → next wake takes 8.B new-PR path on the W9 portion"
      fi
    else
      echo "    W9 PR:          (gh CLI unavailable — install/authenticate to surface W9 chain state)"
    fi
  done
}

cmd_stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "no pid file at $PID_FILE — watcher not running?"
    exit 1
  fi
  pid=$(cat "$PID_FILE")
  if ps -p "$pid" > /dev/null 2>&1; then
    kill "$pid" && echo "sent SIGTERM to watcher (pid=$pid)"
  else
    echo "pid $pid not alive; removing stale pid file"
    rm -f "$PID_FILE"
  fi
}

# ── main poller ─────────────────────────────────────────────────────────────

cmd_run() {
  # single-instance lock
  if [ -f "$PID_FILE" ]; then
    existing=$(cat "$PID_FILE")
    if ps -p "$existing" > /dev/null 2>&1; then
      echo "error: watcher already running (pid=$existing). use 'bash $0 stop' first"
      exit 1
    else
      echo "stale pid file; reclaiming"
    fi
  fi
  echo $$ > "$PID_FILE"
  trap cleanup INT TERM

  log "w2-watcher starting (pid=$$)"
  log "  POLL_INTERVAL=${POLL_INTERVAL}s  SETTLE_WINDOW=${SETTLE_WINDOW}s  MIN_GAP=${MIN_GAP}s"
  log "  ignoring commits by: ${IGNORE_AUTHORS}"

  while true; do
    for role in "${!REPOS[@]}"; do
      repo=${REPOS[$role]}
      name=$(basename "$repo")
      step=${STEP_NAMES[$role]}
      state_file=$STATE_DIR/$role.state

      # default state
      last_seen=""
      last_new=0
      last_run=0
      [ -f "$state_file" ] && source "$state_file"

      # fetch quietly; skip this round if the repo is unreachable
      if ! git -C "$repo" fetch origin main 2>/dev/null; then
        log "[$role] fetch failed; skipping"
        continue
      fi
      current=$(git -C "$repo" rev-parse origin/main 2>/dev/null)

      # first sighting: seed + don't fire (avoids a run on launch
      # just because we've never seen the repo before)
      if [ -z "$last_seen" ]; then
        last_seen=$current
        log "[$role] initialized at ${current:0:12}"
        printf 'last_seen=%s\nlast_new=0\nlast_run=0\n' "$current" > "$state_file"
        continue
      fi

      now=$(date +%s)

      # new commits detected
      if [ "$current" != "$last_seen" ]; then
        total=$(git -C "$repo" rev-list --count "$last_seen..$current" 2>/dev/null || echo 0)
        # count commits NOT authored by the ignore-list (match on name OR email)
        relevant=$(git -C "$repo" log --format='%an|%ae' "$last_seen..$current" 2>/dev/null \
                   | grep -Ev "$IGNORE_AUTHORS" | wc -l | tr -d ' ')
        relevant=${relevant:-0}

        if [ "$relevant" -gt 0 ]; then
          log "[$role] $relevant trackable new commits ($total total): ${last_seen:0:7}..${current:0:7}"
          last_seen=$current
          last_new=$now
        else
          # all new commits were by ignored authors — advance last_seen so we
          # don't re-scan them, but don't arm the settle window
          log "[$role] $total new commits all by ignored authors — skipping"
          last_seen=$current
        fi
      fi

      # eligible to trigger?
      if [ "$last_new" -gt 0 ]; then
        settle_elapsed=$((now - last_new))
        gap_elapsed=$((now - last_run))

        if [ "$settle_elapsed" -ge "$SETTLE_WINDOW" ]; then
          if [ "$gap_elapsed" -ge "$MIN_GAP" ] || [ "$last_run" -eq 0 ]; then
            log "[$role] TRIGGER W2 (settle=$((settle_elapsed/60))min, gap=$((gap_elapsed/60))min)"
            # maw wake fires fresh worktree + fresh claude + sends the task.
            # Output is one-shot print-mode. If it fails mid-workflow the W2
            # spec's own fallback (#telegram-failed learning, retro note)
            # captures partial state. See mobiz/bank-bot workflow-2-track-commit.md.
            #
            # W9 is chained after W2 in the same wake (Option A from 2026-04-21
            # design discussion). One claude session, one worktree, two specs run
            # sequentially. Saves wake cost vs running two parallel watchers and
            # respects the W9 Step 8.0/8.A/8.B detect→amend gate (claude inside
            # the wake will check for an open docs/flow-track-* PR before opening
            # a new one). If the W9 portion is a no-op (no flow-territory commits),
            # the agent should log it in its retro and skip the W9 PR.
            prompt="อ่าน .agent/skills/technical-writer/references/workflow-2-track-commit.md ให้ครบ แล้วรัน W2 จนจบ (รวม Step ${step} Telegram summary). หลังจาก W2 commit + PR + retro เสร็จเรียบร้อย ให้อ่าน .agent/skills/technical-writer/references/workflow-9-track-flows.md ต่อทันที แล้วรัน W9 จนจบเช่นกัน — ตรวจ flow pointer drift, ทำตาม Step 8.0 detect (ถ้ามี open docs/flow-track-* PR ค้างอยู่ → 8.A amend; ถ้าไม่มี → 8.B new PR), เขียน retro แยกตามที่ W9 spec กำหนด. ถ้า W9 เป็น no-op (zero-drift, no flow-territory commits in range) ให้ log ใน retro แล้วจบ pass — ไม่ต้องเปิด PR เปล่า."
            if maw wake "$role" --fresh "$prompt" >> "$LOG_FILE" 2>&1; then
              log "[$role] wake succeeded"
              last_run=$now
              last_new=0
            else
              log "[$role] wake returned non-zero — will retry next settle"
              # leave last_new set so the next settled cycle retries,
              # but don't update last_run (the run didn't happen)
            fi
          else
            log "[$role] settled but MIN_GAP not met ($((gap_elapsed/60))min < $((MIN_GAP/60))min) — deferring"
          fi
        fi
      fi

      # persist
      printf 'last_seen=%s\nlast_new=%s\nlast_run=%s\n' "$last_seen" "$last_new" "$last_run" > "$state_file"
    done

    sleep "$POLL_INTERVAL"
  done
}

# ── entrypoint ──────────────────────────────────────────────────────────────

case "${1:-run}" in
  run)    cmd_run ;;
  status) cmd_status ;;
  stop)   cmd_stop ;;
  *)
    echo "usage: bash $0 [run|status|stop]"
    echo ""
    echo "env overrides: POLL_INTERVAL, SETTLE_WINDOW, MIN_GAP, STATE_DIR, LOG_FILE"
    exit 1
    ;;
esac

#!/usr/bin/env bash
# w2-watcher.sh — watch mobiz + bank-bot for new commits, trigger per-role
# commit-driven workflows with debounce. Originally a pg-writer/bot-writer W2
# watcher (hence the name); now also fires tester W1 full-sweep validation
# against mobiz. Rename deferred to keep blast radius small — the old name is
# still cited in retros/learnings per P-001.
#
# Philosophy: wakes should fire *when there is work to do*, not on a dumb cron.
# When commits do arrive they tend to burst (analysis 2026-04-19: mobiz 54%,
# bank-bot 39% of commits land within 30 min of a prior one), so we wait for
# the burst to settle before triggering — otherwise a wake would fire 3-5
# times in 30 min on the same cluster.
#
# Design (derived from 14-day commit-pattern analysis):
#   - POLL_INTERVAL (5 min)    — check for new commits on origin/main
#   - SETTLE_WINDOW (30 min)   — quiet period after the last new commit;
#                                 we only fire once the repo is quiet for
#                                 this long, so bursts get batched
#   - MIN_GAP (2 hr)           — floor between consecutive runs of the same
#                                 role, even if new commits keep landing.
#                                 Independent per role (pg-writer, bot-writer,
#                                 tester each track their own last_run).
#
# Roles wired today:
#   - pg-writer  — mobiz  — W2 track-commit → W9 track-flows (chained in wake)
#   - bot-writer — bank-bot — W2 track-commit → W9 track-flows (chained in wake)
#   - tester     — mobiz  — W1 validate-integration-tests (full-sweep, no chain)
#
# Note on pg-writer vs tester sharing mobiz: both watch the same repo, but
# each has its own state file and independent settle/min_gap timer. A mobiz
# commit burst triggers both wakes (separately — different roles, different
# skills, different tmux sessions). W9 is chained inside the pg-writer wake
# (not a separate role) because it's owned by the same technical-writer skill.
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
# Tester W1 integration (added 2026-04-21):
#   - Tester W1 is full-sweep static analysis (validates every test-*.sh
#     against the integration-test-writer pattern library). It's "commit-
#     aware" — uses `$PRIOR_BASELINE..HEAD` to scope STALE-candidate surface —
#     but runs the same full sweep regardless. Baseline tracking is internal
#     (docs/test-index.md header), so the watcher only needs to decide WHEN
#     to fire; W1 itself handles WHAT to scope.
#   - W1 has Step 7b Telegram via mcp__tester-telegram__telegram_send (bot
#     `@ampay_test_alert_bot`, chat 2002026175 — user's personal channel,
#     separate from the writer fleet's `telegram` MCP). Registration lives
#     in ~/.claude.json under the mobiz project block.
#   - No chain after W1. Tester W2/W3 are human-triggered workflows (new test
#     authoring, mock-bank drift check), not commit-watchable.
#
# Usage:
#   bash w2-watcher.sh              # foreground (tail -f style logs to stdout)
#   bash w2-watcher.sh &             # background
#   nohup bash w2-watcher.sh > ~/w2-watcher.log 2>&1 &   # persist past shell exit
#   bash w2-watcher.sh status        # show state per role, whether wake is primed
#   bash w2-watcher.sh stop          # kill a running watcher (by pid file)
#
# Override defaults from shell:
#   POLL_INTERVAL=600 SETTLE_WINDOW=900 MIN_GAP=3600 bash w2-watcher.sh

set -u

# Detach stdin from any inherited tty. Defensive: if a user restarts the
# watcher from an interactive zsh without `</dev/null`, the watcher would
# inherit tty, and any child it spawns (maw wake → tmux, regression script
# → docker compose exec) could hit SIGTTIN and hang (observed 2026-04-21
# with 11 SIGSTOP'd processes in a manual regression chain).
exec </dev/null

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

# Route git fetch/pull over HTTPS using gh's stored token (osxkeychain credential
# helper) instead of SSH. ssh-agent is empty on background runs once macOS locks
# the screen / sleeps, so SSH-based fetches deny silently — observed 2026-04-29
# evening: 15h of "fetch failed" with no commits detected, no wakes fired, no
# silent-fail alerts. gh's token lives in keychain shared with the gh CLI and
# stays usable while the user is logged in.
GIT_AUTH_FLAGS=(-c "url.https://github.com/.insteadOf=git@github.com:")

# Resolve this script's directory so we can invoke sibling scripts
# (regression-then-investigate.sh, etc.) via absolute path regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# role → (repo_path, telegram_step_for_wake_prompt)
declare -A REPOS=(
  ["pg-writer"]="$HOME/Code/github.com/kokarat/mobiz-payment-gateway"
  ["bot-writer"]="$HOME/Code/github.com/kokarat/bank-bot"
  ["pg-tester"]="$HOME/Code/github.com/kokarat/mobiz-payment-gateway"
)
declare -A STEP_NAMES=(
  ["pg-writer"]="8b"   # mobiz W2 has Step 8b for Telegram (mcp: telegram)
  ["bot-writer"]="6b"  # bank-bot W2 has Step 6b for Telegram (mcp: telegram)
  ["pg-tester"]="7b"      # mobiz tester W1 has Step 7b for Telegram (mcp: tester-telegram)
)

# Per-role branch patterns. The silent-fail detector uses these to scope its
# PR + commit search so a successful wake by ROLE A (e.g. pg-tester) does not
# mask a silent-fail by ROLE B (e.g. pg-writer) when both watch the SAME repo.
# Verified live 2026-05-07: pg-writer wake hit Anthropic API rate-limit on
# startup → claude exited before reading wake-prompt → 0 work done. Silent-fail
# detector at +60min would have seen pg-tester's PR #420 (feat/tester-validate-)
# and counted it as "wake verified" for pg-writer too, hiding the failure.
declare -A WAKE_BRANCH_PATTERNS=(
  ["pg-writer"]="docs/track- docs/flow-track-"
  ["bot-writer"]="docs/track- docs/flow-track-"
  ["pg-tester"]="feat/tester-validate-"
)

log() {
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*"
}

# Silent-fail detector: after a wake "succeeds" (maw exit 0), claude inside
# can still die silently — auth 401, missing CLI, malformed prompt. Watcher
# can't tell from maw's exit. Belt-and-suspenders: WAKE_VERIFY_TIMEOUT (default
# 60 min) after wake, query gh for any new PR by @me on the role's repo. If
# zero, send Telegram alert via tester-telegram bot (same channel as regression
# fail-telegram for operator visibility).
WAKE_VERIFY_TIMEOUT=${WAKE_VERIFY_TIMEOUT:-3600}
SILENT_FAIL_TG_PROJECT=${SILENT_FAIL_TG_PROJECT:-$HOME/Code/github.com/kokarat/mobiz-payment-gateway}
# Author of commits the workflows produce (W2/W9/W1 commits land via local
# git config). Used by silent-fail detector to count AMEND-path commits in
# addition to NEW PRs.
COMMIT_AUTHOR=${COMMIT_AUTHOR:-amadeusmarsexpress}

send_silent_fail_telegram() {
  local role="$1" repo_slug="$2" wake_ts="$3" elapsed="$4" reason="${5:-}"
  local TOKEN CHAT
  TOKEN=$(jq -r --arg p "$SILENT_FAIL_TG_PROJECT" '.projects[$p].mcpServers["tester-telegram"].env.TELEGRAM_BOT_TOKEN // empty' "$HOME/.claude.json" 2>/dev/null)
  CHAT=$(jq -r --arg p "$SILENT_FAIL_TG_PROJECT" '.projects[$p].mcpServers["tester-telegram"].env.TELEGRAM_DEFAULT_CHAT_ID // empty' "$HOME/.claude.json" 2>/dev/null)
  [ -z "$TOKEN" ] || [ -z "$CHAT" ] && return
  local iso=$(date -r "$wake_ts" '+%Y-%m-%d %H:%M GMT+7')
  local pane_name="${role}-$(date -r "$wake_ts" '+%Y%m%d-%H%M%S')"
  local body
  if [ -n "$reason" ]; then
    # Reason supplied (fast-path: rate-limit / API error captured from pane)
    local safe_reason=$(echo "$reason" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    body="⚠️ <b>Wake startup-fail</b> (${role})
Repo: <code>${repo_slug}</code>
Wake: <code>${iso}</code> ($((elapsed))s ago)
Cause (from pane): <code>${safe_reason}</code>
Pane: <code>${pane_name}</code>
ลอง wait + manual re-fire เมื่อ rate-limit เคลียร์: <code>maw wake ${role} --task '...'</code>"
  else
    # Default: post-WAKE_VERIFY_TIMEOUT silent (no PR / no commit found)
    body="⚠️ <b>Silent wake fail</b> (${role})
Repo: <code>${repo_slug}</code>
Wake: <code>${iso}</code> ($((elapsed/60))min ago)
ไม่มี PR / commit ตาม pattern ของ role นี้ตั้งแต่ wake — claude ตายเงียบ
(auth 401 / silent attach / prompt corrupt / API rate-limit ที่หลุด fast-path).
ตรวจ pane <code>${pane_name}</code> + watcher.log"
  fi
  curl -sf "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$body" \
    -o /dev/null 2>/dev/null
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
    repo_slug=$(echo "$repo" | sed 's|.*/github\.com/||')
    state_file=$STATE_DIR/$role.state
    echo "── $role ──"
    echo "    repo:           $repo_slug"
    echo ""

    # ── trigger gate ──────────────────────────────────────────────────────
    # The settle/min_gap math here decides WHEN the wake fires for this role.
    # Once it does, the wake's prompt is built per-role (see cmd_run): writers
    # run W2→W9 chained; tester runs W1 full-sweep solo.
    echo "  Trigger gate (when to wake):"
    if [ -f "$state_file" ]; then
      source "$state_file"
      now=$(date +%s)
      echo "      last_seen:      ${last_seen:0:12}"
      if [ "${last_new:-0}" -gt 0 ]; then
        age=$((now - last_new))
        settle_left=$((SETTLE_WINDOW - age))
        if [ $settle_left -gt 0 ]; then
          echo "      settling:       $((age/60)) min since last new commit ($((settle_left/60)) min left of settle window)"
        else
          echo "      settled:        new commits ready to trigger"
        fi
      else
        echo "      pending:        nothing new since last run"
      fi
      if [ "${last_run:-0}" -gt 0 ]; then
        gap=$((now - last_run))
        gap_left=$((MIN_GAP - gap))
        if [ $gap_left -gt 0 ]; then
          echo "      min_gap block:  $((gap/60)) min since last run ($((gap_left/60)) min left of min_gap)"
        else
          echo "      min_gap clear:  last run was $((gap/60)) min ago"
        fi
      else
        echo "      first run:      never triggered yet"
      fi
    else
      echo "      (uninitialized — run the watcher once to seed)"
    fi
    echo ""

    # ── downstream chain / full-sweep info (per role) ─────────────────────
    # pg-writer/bot-writer: show W9 chain state (W9 runs after W2 in same wake)
    # tester:               show that W1 is full-sweep, no chain
    if [ "$role" = "pg-tester" ]; then
      echo "  Wake runs: W1 validate-integration-tests (full-sweep, no chain)"
      echo "      scope:          static analysis of every integration-tests/test-*.sh"
      echo "      commit-aware:   STALE candidates scoped to \$PRIOR_BASELINE..HEAD"
      echo "      baseline:       tracked internally in docs/test-index.md header"
    else
      echo "  W9 chain (runs after W2 in same wake):"
      if command -v gh > /dev/null 2>&1; then
        w9_pr=$(gh pr list --repo "$repo_slug" --search "head:docs/flow-track- state:open" --author "@me" --json number,headRefName,title,createdAt --jq '.[0]' 2>/dev/null)
        if [ -n "$w9_pr" ] && [ "$w9_pr" != "null" ]; then
          pr_num=$(jq -r .number <<< "$w9_pr" 2>/dev/null)
          pr_branch=$(jq -r .headRefName <<< "$w9_pr" 2>/dev/null)
          pr_age_iso=$(jq -r .createdAt <<< "$w9_pr" 2>/dev/null)
          echo "      open W9 PR:     #$pr_num ($pr_branch)"
          echo "      opened:         $pr_age_iso"
          echo "      next path:      8.A — amend the open PR (extend cumulative range)"
        else
          echo "      open W9 PR:     none"
          echo "      next path:      8.B — open a new PR (clean cycle)"
        fi
      else
        echo "      (gh CLI unavailable — install/authenticate to surface W9 chain state)"
      fi
    fi
    echo ""
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
  # Resolve maw binary once at startup, before pid lock + main loop. PATH for
  # background processes is whatever the launching shell had at start time —
  # observed 2026-05-01: watcher launched 2026-04-30 13:59 with maw on PATH,
  # then the user's shell setup drifted (maw left PATH). Every wake from
  # 04-30 evening through 05-01 morning fired but exited 127 with
  # "maw: command not found" — last_run never advanced, last_new stayed
  # armed, and the watcher silent-looped 599 trigger attempts in ~17h while
  # K's overnight commit burst (5 mobiz + 2 bank-bot trackable commits)
  # piled up untracked. Resolve now; abort loud if missing.
  #
  # 2026-05-12 follow-up: watcher running since 2026-05-09 14:00 silent-failed
  # 200+ wakes with "unknown command: wake". Root cause: watcher's PATH lacks
  # ~/.local/bin (where the current `maw` install lives, v26.5.7-alpha.752),
  # so `command -v maw` missed it and we fell through to the dist/maw build
  # at $HOME/Code/.../maw-js/dist/maw (v26.4.20-alpha.11 — old enough that
  # `wake` was still a plugin rather than the top-alias it is today). The
  # newer build at ~/.local/bin/maw is the canonical install path; prefer
  # it explicitly so a sparse PATH no longer routes us to a stale dist.
  if [ -z "${MAW_BIN:-}" ]; then
    if [ -x "$HOME/.local/bin/maw" ]; then
      MAW_BIN="$HOME/.local/bin/maw"
    elif command -v maw > /dev/null 2>&1; then
      MAW_BIN=$(command -v maw)
    elif [ -x "$HOME/Code/github.com/Soul-Brews-Studio/maw-js/dist/maw" ]; then
      MAW_BIN="$HOME/Code/github.com/Soul-Brews-Studio/maw-js/dist/maw"
    else
      echo "error: maw not at \$HOME/.local/bin/maw, not on PATH, and not at \$HOME/Code/github.com/Soul-Brews-Studio/maw-js/dist/maw — set MAW_BIN env var or build maw-js (cd maw-js && bun run build)" >&2
      exit 1
    fi
  elif [ ! -x "$MAW_BIN" ]; then
    echo "error: MAW_BIN=$MAW_BIN is not executable" >&2
    exit 1
  fi

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
  log "  maw binary: ${MAW_BIN}"

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
      pending_wake_ts=0
      [ -f "$state_file" ] && source "$state_file"

      # Silent-fail check: did the previous wake actually produce output?
      # Runs before fetch so it fires even on offline rounds. Only checks
      # once per pending wake; clears pending_wake_ts after either result.
      #
      # Two signals (either >0 = wake verified):
      #   1. NEW PRs by @me on this repo since wake     (covers 8.B path)
      #   2. Commits by COMMIT_AUTHOR on any branch     (covers 8.A amend
      #      path — pushed commits to existing PR's branch, no new PR)
      #
      # gh retry: transient keyring/network glitch caused false positives
      # 2026-04-28 (pg-tester PR #326 existed but detector returned 0).
      # Retry once before declaring silent.
      now=$(date +%s)
      if [ "${pending_wake_ts:-0}" -gt 0 ]; then
        pending_elapsed=$((now - pending_wake_ts))
        if [ "$pending_elapsed" -ge "$WAKE_VERIFY_TIMEOUT" ]; then
          repo_slug=$(echo "$repo" | sed 's|.*/github\.com/||')
          iso_filter=$(date -u -r "$pending_wake_ts" '+%Y-%m-%dT%H:%M:%SZ')

          # Build per-role branch filter so a sibling role's success on the
          # same repo doesn't mask THIS role's silent-fail.
          patterns="${WAKE_BRANCH_PATTERNS[$role]:-}"
          pr_search="author:@me created:>=$iso_filter"
          if [ -n "$patterns" ]; then
            head_clause=""
            for p in $patterns; do
              [ -z "$head_clause" ] && head_clause="head:$p" || head_clause="$head_clause head:$p"
            done
            pr_search="$pr_search $head_clause"
          fi

          # Signal 1: NEW PRs by @me on role's branch shape (with retry on gh failure)
          pr_count=""
          for attempt in 1 2; do
            pr_count=$(gh pr list --repo "$repo_slug" --search "$pr_search" --json number --jq 'length' 2>/dev/null) && break
            sleep 10
          done
          pr_count=${pr_count:-0}

          # Signal 2: commits by COMMIT_AUTHOR on role's branch shape since wake.
          # Refresh remote refs first so AMEND-path branches are visible.
          git "${GIT_AUTH_FLAGS[@]}" -C "$repo" fetch origin --prune --quiet 2>/dev/null
          commit_count=0
          if [ -n "$patterns" ]; then
            for p in $patterns; do
              # `--branches` glob expands `*` against ref names; pattern is a prefix here.
              c=$(git -C "$repo" log --remotes="origin/${p}*" \
                --author="$COMMIT_AUTHOR" \
                --since="@$pending_wake_ts" \
                --format=%h 2>/dev/null | wc -l | tr -d ' ')
              commit_count=$((commit_count + ${c:-0}))
            done
          else
            # No pattern (legacy/uncategorized role) — fall back to all-branches.
            commit_count=$(git -C "$repo" log --all --remotes \
              --author="$COMMIT_AUTHOR" \
              --since="@$pending_wake_ts" \
              --format=%h 2>/dev/null | wc -l | tr -d ' ')
            commit_count=${commit_count:-0}
          fi

          total_signal=$((pr_count + commit_count))
          if [ "$total_signal" -eq 0 ]; then
            log "[$role] SILENT-FAIL: 0 PRs + 0 commits matching role pattern in $((pending_elapsed/60))min since wake @ $(date -r "$pending_wake_ts" '+%H:%M') (search: $pr_search) — alerting operator"
            send_silent_fail_telegram "$role" "$repo_slug" "$pending_wake_ts" "$pending_elapsed"
          else
            log "[$role] wake verified: $pr_count new PR(s) + $commit_count commit(s) matching pattern '$patterns' in $((pending_elapsed/60))min"
          fi
          pending_wake_ts=0
        fi
      fi

      # fetch quietly; skip this round if the repo is unreachable
      # pull --ff-only keeps local main synced with origin/main, so worktrees
      # maw creates from `main` ref see the latest commits. Plain `fetch` only
      # advances origin/main — local main stays stale → claude in fresh
      # worktree can't see commits the watcher already detected (observed
      # 2026-04-25..27: bank-bot local main stuck at ffd626b while origin/main
      # advanced 6 commits, every wake's worktree checkout was stale).
      if ! git "${GIT_AUTH_FLAGS[@]}" -C "$repo" pull --ff-only origin main 2>/dev/null; then
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
            log "[$role] TRIGGER wake (settle=$((settle_elapsed/60))min, gap=$((gap_elapsed/60))min)"
            # maw wake fires fresh worktree + fresh claude + sends the task.
            # Output is one-shot print-mode. If it fails mid-workflow, each
            # spec's own fallback (retro note / learning) captures partial state.
            #
            # Prompt branches by role: writers (pg-writer/bot-writer) run
            # W2→W9 chained; tester runs W1 full-sweep solo (no chain, no
            # Telegram step today — see header comment).
            if [ "$role" = "pg-tester" ]; then
              prompt="อ่าน .agent/skills/tester/SKILL.md + .agent/skills/tester/references/workflow-1-validate-integration-tests.md ให้ครบ แล้วรัน W1 validate-integration-tests จนจบ. W1 เป็น full-sweep static analysis ของทุก integration-tests/test-*.sh — ใช้ \$PRIOR_BASELINE..HEAD จาก docs/test-index.md header เพื่อ scope STALE candidates. เสร็จ Step 7 (commit+PR) + Step ${step} (Telegram summary via mcp__tester-telegram__telegram_send — ไม่ใช่ generic telegram MCP ของ writer fleet) + Step 8 (retro) แล้วจบ pass — ไม่ต้อง chain workflow อื่น. ถ้า zero production-surface commits ใน range และ pattern library (\`.agent/skills/integration-test-writer/\`) ไม่ได้แก้ ให้ skip Step 7 PR (no-op) แต่ยังส่ง Telegram short-note ว่า 'วันนี้ validate N tests, 0 regression' เพื่อรักษา cadence, แล้วเขียน retro ว่า no-op."
            else
              # W9 chained after W2 in the same wake (Option A from 2026-04-21
              # design discussion). One claude session, one worktree, two specs
              # run sequentially. Respects the W9 Step 8.0/8.A/8.B detect→amend
              # gate (claude inside the wake will check for an open
              # docs/flow-track-* PR before opening a new one).
              prompt="อ่าน .agent/skills/technical-writer/references/workflow-2-track-commit.md ให้ครบ แล้วรัน W2 จนจบ (รวม Step ${step} Telegram summary). หลังจาก W2 commit + PR + retro เสร็จเรียบร้อย ให้อ่าน .agent/skills/technical-writer/references/workflow-9-track-flows.md ต่อทันที แล้วรัน W9 จนจบเช่นกัน — ตรวจ flow pointer drift, ทำตาม Step 8.0 detect (ถ้ามี open docs/flow-track-* PR ค้างอยู่ → 8.A amend; ถ้าไม่มี → 8.B new PR), เขียน retro แยกตามที่ W9 spec กำหนด. ถ้า W9 เป็น no-op (zero-drift, no flow-territory commits in range) ให้ log ใน retro แล้วจบ pass — ไม่ต้องเปิด PR เปล่า."
            fi

            # File-pointer pattern: maw wake's send-keys path truncates long
            # multi-line Thai/HTML prompts (~600+ bytes) — its "DONE" sentinel
            # leaks into the pasted text mid-sentence, leaving zsh stuck on
            # `cmdand cursh quote>` and claude never starts. Observed live
            # 2026-04-22 01:27 (pg-writer wake) + 02:30 (bot-writer wake) —
            # both succeeded from maw's POV but no W2/W9 ran inside, so no
            # Telegram fired all night.
            #
            # Workaround: write the long prompt to a file in $STATE_DIR and
            # send maw a short pointer command. Same fix applied to the
            # investigation wake in regression-then-investigate.sh.
            mkdir -p "$STATE_DIR/wake-prompts"
            wake_ts=$(date +%Y%m%d-%H%M%S)
            wake_prompt_file="$STATE_DIR/wake-prompts/${role}-${wake_ts}.md"
            printf '%s\n' "$prompt" > "$wake_prompt_file"
            wake_pointer="อ่าน $wake_prompt_file ให้จบก่อน — นั่นคือ task ของคุณ ครบทุกบรรทัด. ทำตามคำสั่งในไฟล์ทั้งหมด ห้ามข้าม."
            # NOTE: --task flag, not positional. Positional [task] becomes
            # wakeOpts.task → slugged into the worktree/tmux-pane name, which
            # with this long Thai pointer produced panes like
            # `cachew2-watcherwake-promptspg-tester-20` that tmux then can't
            # resolve. `--task <prompt>` maps to wakeOpts.prompt and goes to
            # Claude as-is without touching names. See maw-js wake plugin
            # index.ts:80 vs :93.
            # --wt with unique timestamp prevents maw from silent-attaching
            # to a stale pane (observed 2026-04-25 + 04-26: bot-writer pane
            # %52 had a claude session running 4+ days, every new wake hit
            # "session exists" and exited 0 without spawning W2 — backlog of
            # 3 wakes / 5 commits silently dropped).
            if "$MAW_BIN" wake "$role" --wt "$wake_ts" --task "$wake_pointer" --fresh >> "$LOG_FILE" 2>&1; then
              log "[$role] wake succeeded"
              last_run=$now
              last_new=0
              pending_wake_ts=$now  # arm silent-fail detector

              # Recover from maw's `claude --continue || claude -p` template
              # bug: --continue exits 0 with "No conversation found" in fresh
              # panes, so the || fallback never fires and claude -p never
              # runs. We compounded this with --wt unique (every wake = fresh
              # pane = no prior conversation = template always fails). 5s
              # after wake, check if the pane is back at shell prompt with
              # "No conversation found" visible — if so, send-keys claude -p
              # directly to actually run the prompt.
              sleep 5
              case "$role" in
                pg-writer|pg-tester) wake_session=03-payment-gateway ;;
                bot-writer)          wake_session=02-bank-bot ;;
                *)                   wake_session="" ;;
              esac
              wake_target="${wake_session}:${role}-${wake_ts}"
              wake_pane_cmd=$(tmux list-panes -t "$wake_target" -F "#{pane_current_command}" 2>/dev/null | head -1)
              if [ -n "$wake_pane_cmd" ] && echo "$wake_pane_cmd" | grep -qE "^(zsh|bash|sh|fish)$"; then
                wake_pane_content=$(tmux capture-pane -t "$wake_target" -pS -25 2>/dev/null)
                if echo "$wake_pane_content" | grep -q "No conversation found to continue"; then
                  log "[$role] template fallback didn't fire — sending claude -p directly"
                  tmux send-keys -t "$wake_target" "claude --dangerously-skip-permissions -p '$wake_pointer'" Enter
                # Detect Anthropic API rate-limit / startup error: claude exits
                # within seconds and the pane drops back to shell prompt with
                # the error visible. Without this fast-path, we'd wait
                # WAKE_VERIFY_TIMEOUT (60min) before silent-fail detector ran —
                # operator gets no signal until then. Verified live 2026-05-07
                # 10:34: pg-writer wake hit "API Error: ... Rate limited" and
                # exited; the silent-fail check at +60min would have been
                # masked by pg-tester's PR (same repo, basename-only filter).
                # Fix is twofold: per-role branch filter (above) + this fast
                # path Telegram alert so the operator knows immediately why
                # the wake produced nothing.
                elif echo "$wake_pane_content" | grep -qE "API Error|Rate limited|usage limit"; then
                  startup_err=$(echo "$wake_pane_content" | grep -E "API Error|Rate limit|usage limit" | head -1 | tr -d '\r')
                  log "[$role] startup-fail detected within 5s of wake: $startup_err"
                  # repo_slug isn't guaranteed to be set in this scope (the
                  # silent-fail block above only computes it when its own
                  # branch fires). Compute fresh.
                  fast_repo_slug=$(echo "$repo" | sed 's|.*/github\.com/||')
                  send_silent_fail_telegram "$role" "$fast_repo_slug" "$pending_wake_ts" 5 "$startup_err"
                  # Don't clear pending_wake_ts — leave it armed so the +60min
                  # check still runs (in case of recovery / out-of-band wake).
                fi
              fi

              # Send-keys race fast-path (added 2026-05-14 after recurring
              # silent fails on 2026-05-12 13:01 + 2026-05-14 03:34 — both
              # pg-writer + pg-tester wakes against the 66.3k-char mobiz
              # CLAUDE.md): maw wake reports success but the inject-prompt
              # send-keys lands while claude TUI is still loading
              # CLAUDE.md, so the keys hit the bracketed-paste buffer
              # before it's wired up and silently drop. The shell-prompt
              # block above doesn't catch this — pane is in claude TUI
              # (not back at shell), just sitting at empty `❯ ` with no
              # task in flight. Without this gate the +60min silent-fail
              # detector is the only alarm; operator wastes an hour per
              # incident and recovers manually via `tmux paste-buffer`.
              # Detection: 30s post-wake (5s slept above + 25s here), if
              # pane is in claude TUI and the prompt's Thai "อ่าน"
              # sentinel is absent from scrollback, the keys never landed
              # — paste-buffer the saved prompt file + send-keys Enter,
              # which is the exact recovery we run by hand today.
              sleep 25
              race_pane_cmd=$(tmux list-panes -t "$wake_target" -F "#{pane_current_command}" 2>/dev/null | head -1)
              if [ -n "$race_pane_cmd" ] && ! echo "$race_pane_cmd" | grep -qE "^(zsh|bash|sh|fish)$" && [ -r "$wake_prompt_file" ]; then
                race_pane_content=$(tmux capture-pane -t "$wake_target" -pS -50 2>/dev/null)
                if ! echo "$race_pane_content" | grep -q "อ่าน"; then
                  log "[$role] send-keys race detected — prompt absent from pane after 30s, resending via paste-buffer"
                  tmux load-buffer -b "wake-resend-${role}" "$wake_prompt_file" 2>/dev/null
                  tmux paste-buffer -b "wake-resend-${role}" -t "$wake_target" -p 2>/dev/null
                  sleep 1
                  tmux send-keys -t "$wake_target" Enter 2>/dev/null
                  log "[$role] resent prompt via paste-buffer"
                fi
              fi

              # Chain regression runner in the background after two triggers:
              #   - pg-tester (mobiz W1 validate pass): full-sweep integration
              #     after a mobiz commit burst
              #   - bot-writer (bank-bot W2 commit-track pass): bank-bot code is
              #     loaded into the same integration stack (bank-bot container
              #     builds from $MOBIZ/bank-bot), so a bank-bot commit also
              #     warrants a regression run against mobiz main + new bot.
              #
              # The regression script gates on `Newly-broken = 0` in the
              # freshly-written docs/test-index.md; if W1 flagged broken tests,
              # it skips regression and Telegrams a "skipped" note. For the
              # bot-writer trigger, the gate reads whichever docs/test-index.md
              # the last pg-tester run left behind (orthogonal concern — the
              # gate is about mobiz test-file validity, not bank-bot state).
              #
              # Keep the watcher loop unblocked — the runner can take 30-60 min.
              # Concurrent fires (e.g. mobiz + bank-bot push minutes apart) are
              # handled by the runner's own single-instance lockfile, which
              # skips + Telegrams "another regression running" without racing
              # on the shared docker stack.
              if [ "$role" = "pg-tester" ] || [ "$role" = "bot-writer" ]; then
                log "[$role] chaining regression-then-investigate.sh (fire-and-forget)"
                # </dev/null is load-bearing: without it, deep children (docker
                # compose exec) inherit stdin from the parent's tty and can
                # receive SIGTTIN when trying to read term-size / auth prompts
                # → process stops with state T → whole chain hangs. Fixed
                # 2026-04-21 after a live regression hung for 17+ min with 11
                # SIGSTOP'd processes. nohup alone (without </dev/null) is
                # insufficient when spawned from an interactive-tty context.
                nohup bash "$SCRIPT_DIR/regression-then-investigate.sh" \
                  </dev/null >> "$STATE_DIR/regression.log" 2>&1 &
                disown
              fi
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
      printf 'last_seen=%s\nlast_new=%s\nlast_run=%s\npending_wake_ts=%s\n' "$last_seen" "$last_new" "$last_run" "$pending_wake_ts" > "$state_file"
    done

    # sleep in 1-second ticks instead of one long sleep. Lets the INT/TERM
    # trap fire within ~1s instead of waiting for a 5-min `sleep` child to
    # exit first (bash queues signals while a child is running — fix
    # prompted by 2026-04-21 watcher-restart incident where `stop` appeared
    # to hang for minutes before the trap ran).
    for _ in $(seq 1 "$POLL_INTERVAL"); do sleep 1; done
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

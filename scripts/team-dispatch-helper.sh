#!/usr/bin/env bash
# team-dispatch-helper.sh — orchestrator's spawn helper for the team-dispatch
# (workflow-2-team-dispatch) replacement of the legacy envelope+watcher loop.
#
# What it does (one call = one teammate spawned):
#   1. Resolve the target repo via ghq.
#   2. Create-or-reuse a per-(campaign × repo) worktree at <repo>.wt-c-<slug>
#      on branch campaign/<slug>. The locked granularity is shared-across-roles
#      within the same (campaign, repo) — see AGENTS.md §8b (locked 2026-05-29).
#   3. Inject the .agent + .secrets symlinks the worktree needs (per §3a/§3b).
#   4. `maw team create <slug>` (idempotent) + `maw team spawn <slug> <role>
#      --model sonnet --prompt …` WITHOUT --exec — captures the claude command
#      so we can split the tmux pane ourselves with `-c <wt>` (the team plugin's
#      spawnTeammatePane has no cwd flag yet, layout-manager.ts L119; this
#      wrapper closes that gap without patching maw-js).
#   5. `tmux split-window -c <wt-path>` in the orchestrator's current window →
#      the agent runs in its own pane, in its own worktree, cwd-correct.
#
# Why this replaces the watcher dispatch path:
#   • the watcher's silent-fail modes (delivered_to_owner ≠ delivered,
#     dual-wake collision, stale state on resume — see learnings 2026-05-29)
#     only fire for envelope+send-keys dispatch. team-spawn opens a fresh
#     claude process in a fresh pane — no send-keys race, no JSONL gate to
#     misread, no §151 owner record to clear by hand.
#   • cleanup is explicit (`team-dispatch-finish.sh`) instead of relying on
#     watcher gc, removing the worktree-sprawl class entirely.
#
# Usage:
#   team-dispatch-helper.sh \
#       --campaign <slug>          campaign id (e.g. perfcf, payoutfix)
#       --role     <role>          target agent role (brew-ops, pg-writer, …)
#       --repo     <gh-path>       github.com/<owner>/<repo>
#       --prompt   "<text>"        task body for the agent
#       [--model   <model>]        default: opus (resolves to opus 4.8)
#       [--dry-run]                print actions, change nothing
#
# Owner: brew-ops. Source of truth: this file. Paired with
# scripts/team-dispatch-finish.sh and references/workflow-2-team-dispatch.md.

set -uo pipefail
SCRIPT_NAME=$(basename "$0")
die() { printf '\033[31m✗\033[0m %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }

# --- args ---
CAMPAIGN=""; ROLE=""; REPO=""; PROMPT=""; MODEL="opus"; DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --campaign) CAMPAIGN=${2:-}; shift 2 ;;
    --role)     ROLE=${2:-};     shift 2 ;;
    --repo)     REPO=${2:-};     shift 2 ;;
    --prompt)   PROMPT=${2:-};   shift 2 ;;
    --model)    MODEL=${2:-};    shift 2 ;;
    --dry-run)  DRY_RUN=1;       shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    *)          die "unknown arg: $1" ;;
  esac
done
[ -n "$CAMPAIGN" ] || die "missing --campaign"
[ -n "$ROLE" ]     || die "missing --role"
[ -n "$REPO" ]     || die "missing --repo"
[ -n "$PROMPT" ]   || die "missing --prompt"
[ -n "${TMUX:-}" ] || die "must run inside a tmux session (TMUX not set)"

# --- paths ---
GHQ_ROOT=$(ghq root 2>/dev/null) || die "ghq not installed (brew install ghq)"
REPO_PATH="$GHQ_ROOT/$REPO"
[ -d "$REPO_PATH" ] || die "repo not found at $REPO_PATH (try: ghq get $REPO)"

WT_PATH="${REPO_PATH}.wt-c-${CAMPAIGN}"
BRANCH="campaign/${CAMPAIGN}"
CENTRAL_AGENT="$HOME/Code/github.com/kxlahsimx09/mb_agent_oracle_memory/$REPO/.agent"
SECRETS_STORE="$HOME/.arra-oracle-v2/fleet-secrets/$(basename "$REPO")"

cat <<EOF
team-dispatch-helper:
  campaign : $CAMPAIGN
  role     : $ROLE
  repo     : $REPO
  wt-path  : $WT_PATH
  branch   : $BRANCH
  model    : $MODEL
  prompt   : $(printf '%.80s' "$PROMPT")$([ ${#PROMPT} -gt 80 ] && echo '…')
EOF
[ -n "$DRY_RUN" ] && { echo; echo "(dry-run; no changes)"; exit 0; }

# --- 1. worktree (create-or-reuse) ---
if [ -d "$WT_PATH" ]; then
  ok "worktree exists — reusing (shared across roles within campaign×repo)"
else
  if git -C "$REPO_PATH" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO_PATH" worktree add "$WT_PATH" "$BRANCH" >/dev/null \
      || die "worktree add failed (existing branch $BRANCH)"
    ok "worktree added on existing branch $BRANCH"
  else
    git -C "$REPO_PATH" worktree add "$WT_PATH" -b "$BRANCH" >/dev/null \
      || die "worktree add failed (new branch $BRANCH)"
    ok "worktree added with new branch $BRANCH"
  fi

  # --- 2. .agent symlink (per AGENTS.md §3a) ---
  if [ -e "$CENTRAL_AGENT" ] && [ ! -e "$WT_PATH/.agent" ]; then
    ln -s "$CENTRAL_AGENT" "$WT_PATH/.agent" && say "+ .agent → $CENTRAL_AGENT"
  fi
  # --- 3. .secrets symlink (per AGENTS.md §3b) ---
  if [ -d "$SECRETS_STORE" ] && [ ! -e "$WT_PATH/.secrets" ]; then
    ln -s "$SECRETS_STORE" "$WT_PATH/.secrets" && say "+ .secrets → $SECRETS_STORE"
  fi
fi

# --- 4. ensure maw team manifest (idempotent) ---
maw team create "$CAMPAIGN" >/dev/null 2>&1 || true

# --- 5. capture spawn cmd (without --exec; we want to set cwd on the split) ---
spawn_out=$(maw team spawn "$CAMPAIGN" "$ROLE" --model "$MODEL" --prompt "$PROMPT" 2>&1) \
  || die "maw team spawn failed:
$spawn_out"
# The team plugin prints `  Run: <claude cmd>` when --exec is omitted, with ANSI
# color escapes around `Run:` (cyan). Strip CSI sequences before parsing — the
# raw bytes are `\033[36mRun:\033[0m`, which a literal `^  Run:` regex misses
# entirely. Found 2026-05-29 (thread #257; orchestrator's diagnosis attributed
# this to maw-js's missing `./oracle-members` import — that is a separate bug
# in `members`/`delete`, not in `spawn`).
CMD=$(printf '%s\n' "$spawn_out" | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g' | sed -n 's/^  Run: //p' | head -1)
[ -n "$CMD" ] || die "could not extract claude cmd from spawn output:
$spawn_out"

# --- 6. tmux new-window with cwd = worktree ---
# CRITICAL: a separate window, NOT split-window. The orchestrator-guard hook
# self-gates on tmux window_name matching `orchestrator-*`. A teammate spawned
# as a split-pane inside the orchestrator's own window inherits that window_name,
# so its Edit/Write gets BLOCKED — the guard mistakes the teammate for the
# orchestrator and the agent cannot do the very work it was dispatched to do.
# A dedicated window named `<role>-<campaign>` keeps the guard a no-op for the
# teammate, so it edits code/docs normally without bypassing the guard.
# (Confirmed 2026-05-30: split-pane in `orchestrator-o1` → guard exit 2;
#  separate window `next-writer-<slug>` → guard exit 0.)
WINDOW_NAME="${ROLE}-${CAMPAIGN}"
PANE=$(tmux new-window ${GROUP:+-t "$GROUP:"} -n "$WINDOW_NAME" -c "$WT_PATH" -P -F '#{pane_id}' "$CMD") \
  || die "tmux new-window failed"
ok "spawned in window '$WINDOW_NAME' pane $PANE (cwd: $WT_PATH)"

# --- 7. summary ---
cat <<EOF

agent dispatched:
  window   : $WINDOW_NAME
  pane     : $PANE
  campaign : $CAMPAIGN
  role     : $ROLE
  worktree : $WT_PATH

next:
  send a message:   maw team send $CAMPAIGN $ROLE "<text>"
  close campaign:   $(dirname "$0")/team-dispatch-finish.sh --campaign $CAMPAIGN
EOF

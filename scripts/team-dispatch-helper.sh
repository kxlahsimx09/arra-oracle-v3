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
#      --model opus` (NO --prompt — see Step 5 note) WITHOUT --exec — captures
#      the claude command so we can launch it ourselves with `-c <wt>` (the team
#      plugin's spawnTeammatePane has no cwd flag yet, layout-manager.ts L119;
#      this wrapper closes that gap without patching maw-js).
#   5. `tmux new-window -c <wt-path>` (its OWN window, not a split-pane in the
#      orchestrator's window — else the orchestrator-guard hook blocks the
#      teammate's edits; see Step 6). The agent runs in its own window/worktree,
#      cwd-correct, on opus 4.8.
#   6.5 Deliver the task ($PROMPT) as the FIRST USER TURN via send-keys after the
#      TUI is ready. The task must NOT go through --prompt: the team plugin folds
#      --prompt into the system prompt, which makes the task background persona,
#      not an actionable turn — the agent then idles into its role's standing
#      agenda (observed 2026-05-30, gapqwin). System prompt = role identity only.
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

# --- 1. worktree (create-or-reuse) + freshness (hybrid refresh policy) -------
# Freshness handling used to exist ONLY on the new-branch path below; reuse and
# existing-branch checkouts inherited a stale tip and nothing advanced them, so
# teammates dispatched into a days-old campaign started N commits behind upstream.
# worktree-freshen.sh is the single source of truth for the fast-forward-only
# "advance" policy. It returns a STALE banner on stdout when it can't safely
# advance the tree; we inject that into the teammate's kickoff turn.
FRESHEN="$(dirname "$0")/worktree-freshen.sh"
STALE_BANNER=""
if [ -d "$WT_PATH" ]; then
  ok "worktree exists — reusing (shared across roles within campaign×repo)"
  # Reuse path: the dir may already hold a live teammate. freshen fetches and
  # fast-forwards only when clean+idle, else hands back a staleness banner.
  STALE_BANNER=$("$FRESHEN" --repo "$REPO_PATH" --wt "$WT_PATH" \
                            --campaign "$CAMPAIGN" --mode reuse)
else
  # Refresh origin/main so a NEW campaign branch always bases off fresh upstream,
  # never the base checkout's (possibly stale / WIP / detached) local HEAD.
  git -C "$REPO_PATH" fetch origin main --quiet \
    || say "⚠ fetch origin main failed (offline?) — basing on existing origin/main"
  if git -C "$REPO_PATH" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO_PATH" worktree add "$WT_PATH" "$BRANCH" >/dev/null \
      || die "worktree add failed (existing branch $BRANCH)"
    ok "worktree added on existing branch $BRANCH"
    # Existing branch = a tip from a prior run; advance it onto fresh origin/main.
    # No agent is in the just-created worktree yet, so a clean ff is safe here.
    STALE_BANNER=$("$FRESHEN" --repo "$REPO_PATH" --wt "$WT_PATH" \
                              --campaign "$CAMPAIGN" --mode checkout)
  else
    git -C "$REPO_PATH" worktree add "$WT_PATH" -b "$BRANCH" origin/main >/dev/null \
      || die "worktree add failed (new branch $BRANCH off origin/main)"
    ok "worktree added with new branch $BRANCH (based on fresh origin/main)"
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
# Prepend the staleness banner (if any) so the teammate reconciles the tree
# before trusting it — the agent owns the *how* (merge / rebase / proceed).
if [ -n "$STALE_BANNER" ]; then
  say "⚠ stale base — injecting reconcile banner into kickoff turn"
  PROMPT="${STALE_BANNER}

${PROMPT}"
fi

# --- 4. ensure maw team manifest (idempotent) ---
maw team create "$CAMPAIGN" >/dev/null 2>&1 || true

# --- 5. capture spawn cmd (without --exec; we want to set cwd on the split) ---
# NOTE: we do NOT pass --prompt here. The team plugin folds --prompt into the
# --system-prompt-file (role identity), NOT a user turn — so a spawned claude
# wakes with the task as "background persona" but no message to act on, and
# drifts into its role's standing agenda instead (observed 2026-05-30, campaign
# gapqwin: next-writer ran CF-gateway pointers instead of the dispatched task).
# Fix: system prompt = role identity only (maw still writes "You are '<role>'…");
# the task ($PROMPT) is delivered as the FIRST USER TURN in Step 6.5 below.
spawn_out=$(maw team spawn "$CAMPAIGN" "$ROLE" --model "$MODEL" 2>&1) \
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

# Record the teammate's pane id into the team config. `maw team spawn` (above) ran
# BEFORE this window existed, so it registered the member with no `tmuxPaneId` — only
# split-pane layouts get one. Without it, window-name→role tools (the Fleet Town map,
# oracle-studio) can't link this separate-window teammate to its team and it falls to
# the commons. Best-effort: a failure here never blocks the spawn.
TEAM_CFG="$HOME/.claude/teams/$CAMPAIGN/config.json"
if [ -f "$TEAM_CFG" ] && command -v python3 >/dev/null 2>&1; then
  TEAM_CFG="$TEAM_CFG" ROLE="$ROLE" PANE="$PANE" python3 - <<'PY' && ok "recorded pane $PANE in team '$CAMPAIGN'" || ok "(note: could not record pane id in team config — Fleet Town may show this teammate in commons)"
import json, os
p, role, pane = os.environ["TEAM_CFG"], os.environ["ROLE"], os.environ["PANE"]
c = json.load(open(p))
# the member maw just appended is the LAST one with this role
idx = [i for i, m in enumerate(c.get("members", [])) if m.get("name") == role]
if not idx:
    raise SystemExit(1)
c["members"][idx[-1]]["tmuxPaneId"] = pane
json.dump(c, open(p, "w"), indent=2)
PY
fi

# --- 6.5. deliver the task as the FIRST USER TURN ---------------------------
# The spawned claude has the role identity in its system prompt but no message
# to act on yet. Send the dispatch contract ($PROMPT) as the kickoff turn so it
# starts working instead of idling into its role's standing agenda.
#
# Two hard-won details:
#  1. Wait for the TUI to be ready before send-keys — a fresh `claude` takes a
#     few seconds to boot; keystrokes sent before the input box exists are lost.
#     We poll capture-pane for the input affordance, with a timeout fallback.
#  2. Bracketed-paste safety: send the text as one `-l` literal, sleep, THEN
#     Enter as a SEPARATE send-keys. Text+Enter in one call lets the TUI's
#     bracketed-paste swallow the newline → the line never submits (this was the
#     22-minute stall on the first gapqwin spawn). Mirrors inbox-watcher.sh.
KICKOFF_READY_TIMEOUT=${KICKOFF_READY_TIMEOUT:-45}
KICKOFF_ENTER_DELAY=${KICKOFF_ENTER_DELAY:-1}
ready=0
for _ in $(seq 1 "$KICKOFF_READY_TIMEOUT"); do
  # claude's input box / hint line appears when it's ready for a turn
  if tmux capture-pane -t "$PANE" -p 2>/dev/null \
       | grep -qiE 'shortcuts|│ >|╰|Try ".*"'; then
    ready=1; break
  fi
  sleep 1
done
[ "$ready" = "1" ] || say "⚠ TUI readiness not detected after ${KICKOFF_READY_TIMEOUT}s — sending kickoff anyway"
tmux send-keys -t "$PANE" -l -- "$PROMPT"
sleep "$KICKOFF_ENTER_DELAY"
tmux send-keys -t "$PANE" Enter
ok "kickoff turn delivered ($([ "$ready" = 1 ] && echo 'TUI ready' || echo 'timeout fallback'))"

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

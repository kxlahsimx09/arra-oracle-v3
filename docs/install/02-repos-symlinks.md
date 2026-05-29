# 02 — Repos, Roles & Symlink Topology

## ghq Root (binding constraint)

`scripts/team-dispatch-helper.sh` contains this **hardcoded path**:

```bash
CENTRAL_AGENT="$HOME/Code/github.com/kxlahsimx09/mb_agent_oracle_memory/$REPO/.agent"
SECRETS_STORE="$HOME/.arra-oracle-v2/fleet-secrets/$(basename "$REPO")"
```

`ghq root` **must** return `$HOME/Code`. Configure before cloning:

```bash
git config --global ghq.root "$HOME/Code"
```

---

## Repo Inventory

| Repo | Role | Port | Branch (primary) |
|------|------|------|-----------------|
| `Soul-Brews-Studio/arra-oracle-v3` | Oracle HTTP API + MCP server | **:47778** | `feat/all-prs-rebased` |
| `Soul-Brews-Studio/maw-js` | Multi-agent orchestration CLI + API | **:3456** | `feat/all-prs-rebased` |
| `Soul-Brews-Studio/oracle-studio` | React dashboard (proxies /api/* → :47778) | **:3000** (dev) | `main` |
| `kxlahsimx09/mb_agent_oracle_memory` | Central `.agent/` + ψ vault (source of truth) | — | `main` |
| `kokarat/mobiz-payment-gateway` | Payment gateway (#current fleet member) | — | `main` |
| `kokarat/bank-bot` | Playwright bank bot (#current fleet member) | — | `main` |
| `kxlahsimx09/mb-next-payment-gateway` | Next-gen gateway (#next, stays on `main`) | — | `main` |

### Clone all at once

```bash
ghq get kxlahsimx09/mb_agent_oracle_memory
ghq get Soul-Brews-Studio/arra-oracle-v3
ghq get Soul-Brews-Studio/maw-js
ghq get Soul-Brews-Studio/oracle-studio
ghq get kokarat/mobiz-payment-gateway
ghq get kokarat/bank-bot
ghq get kxlahsimx09/mb-next-payment-gateway
```

---

## Runtime-Checkout Discipline (§3c)

Two primary checkouts are **live runtimes**, not scratch space:

| Primary checkout | Runtime role |
|---|---|
| `~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3` | cwd of `inbox-watcher.sh` daemon |
| `~/Code/github.com/Soul-Brews-Studio/maw-js` | what `~/.local/bin/maw` execs on every call |

**Rules (binding on every agent):**

1. Both stay on `feat/all-prs-rebased`. Never park on a feature branch.
2. New code: branch → PR into `feat/all-prs-rebased` → merge →
   `git fetch && git merge --ff-only` on the primary.
3. Never live-edit files in a running checkout.
4. After re-syncing arra-oracle-v3, restart inbox-watcher
   (`stop` then `start`) — the bash daemon re-reads its file on restart.
5. `mb-next-payment-gateway` primary stays on `main`
   (not a runtime, but local `main` is the worktree freshness anchor).

---

## Symlink Topology

```
mb_agent_oracle_memory/                      ← central repo
├── github.com/
│   ├── Soul-Brews-Studio/
│   │   └── arra-oracle-v3/.agent/           ← source of .agent content
│   ├── kokarat/
│   │   ├── mobiz-payment-gateway/.agent/
│   │   └── bank-bot/.agent/
│   └── kxlahsimx09/
│       └── mb-next-payment-gateway/.agent/
└── ψ/                                        ← canonical vault root
    └── memory/{learnings,retrospectives,traces,resonance}/

~/.arra-oracle-v2/
├── oracle.db                                 ← SQLite knowledge base
├── lancedb/                                  ← vector embeddings
├── fleet-secrets/                            ← secrets store (chmod 700)
│   └── <repo>/supabase.env                  ← chmod 600
└── ψ  →  mb_agent_oracle_memory/ψ           ← symlink (canonical vault)

<repo>/.agent  →  mb_agent_oracle_memory/github.com/<owner>/<repo>/.agent
<repo>.wt-*/.secrets  →  ~/.arra-oracle-v2/fleet-secrets/<repo>
```

### Wire the symlinks

```bash
MEM=~/Code/github.com/kxlahsimx09/mb_agent_oracle_memory

# ψ vault symlink (canonical — everything writes here)
ln -sfn "$MEM/ψ" ~/.arra-oracle-v2/ψ

# .agent symlinks for each repo
for PAIR in \
  "Soul-Brews-Studio/arra-oracle-v3" \
  "kokarat/mobiz-payment-gateway" \
  "kokarat/bank-bot" \
  "kxlahsimx09/mb-next-payment-gateway"
do
  REPO_PATH="$HOME/Code/github.com/$PAIR"
  AGENT_SRC="$MEM/github.com/$PAIR/.agent"
  [ -d "$AGENT_SRC" ] && ln -sfn "$AGENT_SRC" "$REPO_PATH/.agent" \
    && echo "✓ $PAIR/.agent → $AGENT_SRC"
done

# .secrets symlinks for worktrees are injected automatically by maw at
# worktree creation (injectWorktreeSymlinks in maw-js src/commands/shared/
# wake-session.ts). For pre-existing worktrees run:
bash ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3/scripts/backfill-worktree-secrets.sh <repo>
```

### Sanity check

```bash
ls -la ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3/.agent
# Expected: lrwxr-xr-x ... .agent → .../mb_agent_oracle_memory/.../arra-oracle-v3/.agent

ls -la ~/.arra-oracle-v2/ψ
# Expected: lrwxr-xr-x ... ψ → .../mb_agent_oracle_memory/ψ
```

---

## maw Fleet Config

The tmux fleet layout is defined in `.agent/fleet/10-soul-brews.json`:

```json
{
  "name": "10-soul-brews",
  "windows": [
    { "name": "brew-ops-oracle", "repo": "Soul-Brews-Studio/arra-oracle-v3" }
  ],
  "project_repos": [
    "Soul-Brews-Studio/arra-oracle-v3",
    "Soul-Brews-Studio/maw-js",
    "Soul-Brews-Studio/oracle-studio"
  ]
}
```

Bootstrap the fleet in tmux:

```bash
tmux new-session -s soul-brews -d
maw fleet boot 10-soul-brews   # or: maw wake brew-ops
```

---

## Branching Convention (§3d)

Always branch off `origin/main` explicitly (never local `main`):

```bash
git fetch origin --quiet
git switch -c <role>/<slug> origin/main
```

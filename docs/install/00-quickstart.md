# macOS Server Migration — QUICKSTART

Copy-paste run-book for an agent standing up the full Soul-Brews oracle stack
on a fresh macOS server. Each `→` link points to the detailed section.

> **Before you start:** every script reads `$HOME` from the shell environment;
> paths like `/Users/dev01` in plist templates and helper scripts are substituted
> via `__HOME__` at install time. If your home directory is not `/Users/dev01`
> the substitution still works — but double-check any hardcoded example paths in
> docs against your actual `$HOME`.

---

## Phase 0 — System deps  → [01-deps.md](01-deps.md)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install git tmux ghq gh jq curl lsof
curl -fsSL https://bun.sh/install | bash && source ~/.bashrc
bun --version   # must be ≥ 1.2.0

# Local embedder (default — bge-m3)
brew install ollama
ollama pull bge-m3
```

---

## Phase 1 — ghq root (REQUIRED)

```bash
# team-dispatch-helper.sh hardcodes $HOME/Code/github.com/<owner>/<repo>
git config --global ghq.root "$HOME/Code"
mkdir -p "$HOME/Code"
```

---

## Phase 2 — Clone repos  → [02-repos-symlinks.md](02-repos-symlinks.md)

```bash
ghq get kxlahsimx09/mb_agent_oracle_memory   # central .agent + ψ vault
ghq get Soul-Brews-Studio/arra-oracle-v3
ghq get Soul-Brews-Studio/maw-js
ghq get Soul-Brews-Studio/oracle-studio
ghq get kokarat/mobiz-payment-gateway
ghq get kokarat/bank-bot
ghq get kxlahsimx09/mb-next-payment-gateway
```

---

## Phase 3 — Secrets  → [03-secrets.md](03-secrets.md)

```bash
mkdir -p ~/.arra-oracle-v2/fleet-secrets && chmod 700 ~/.arra-oracle-v2/fleet-secrets
# scp / rsync from old server:
#   ~/.arra-oracle-v2/fleet-secrets/<repo>/supabase.env
#   ~/.cache/brew-ops-bot/.env
#   ~/.cache/orchestrator-bot/.env
#   ~/.claude.json  (engine OAuth tokens)
```

---

## Phase 4 — Data  → [04-data.md](04-data.md)

```bash
rsync -a --progress old-server:~/.arra-oracle-v2/ ~/.arra-oracle-v2/
cd ~/Code/github.com/kxlahsimx09/mb_agent_oracle_memory
git fetch --all && git merge --ff-only origin/main
```

---

## Phase 5 — Build

```bash
ARRA=~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
cd "$ARRA" && git checkout feat/all-prs-rebased && bun install && bun run db:push

cd ~/Code/github.com/Soul-Brews-Studio/maw-js
git checkout feat/all-prs-rebased && bun install

cd ~/Code/github.com/Soul-Brews-Studio/oracle-studio
bun install && bun run build
```

---

## Phase 6 — Symlinks + env  → [02-repos-symlinks.md](02-repos-symlinks.md)

```bash
MEM=~/Code/github.com/kxlahsimx09/mb_agent_oracle_memory
ARRA=~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3

ln -sfn "$MEM/github.com/Soul-Brews-Studio/arra-oracle-v3/.agent" "$ARRA/.agent"
ln -sfn "$MEM/ψ" ~/.arra-oracle-v2/ψ

cp "$ARRA/.env.example" "$ARRA/.env"
# Edit .env: set ORACLE_DATA_DIR=$HOME/.arra-oracle-v2
```

---

## Phase 7 — Daemons  → [05-daemons.md](05-daemons.md)

```bash
ARRA=~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3

# 1. Oracle HTTP — verify first
bun --cwd "$ARRA" run server &
sleep 3 && curl -s http://localhost:47778/api/health | jq .

# 2. inbox-watcher — launchd (KeepAlive=true)
bash "$ARRA/scripts/install-inbox-watcher-supervisor.sh"

# 3–5. nohup daemons
nohup bash "$ARRA/scripts/w2-watcher.sh" \
  >> ~/.cache/soul-brews-startup/w2-watcher.log 2>&1 &
nohup bash "$ARRA/scripts/brew-ops-bot/bot.sh" \
  >> ~/.cache/brew-ops-bot/bot.log 2>&1 &
nohup bash "$ARRA/scripts/orchestrator-bot/bot.sh" \
  >> ~/.cache/orchestrator-bot/bot.log 2>&1 &
```

---

## Phase 8 — MCP + sub-agents  → [06-verify.md](06-verify.md)

```bash
# Add to ~/.claude.json mcpServers:
#   "arra-oracle-v3": { "command":"bun", "args":["run","<ARRA>/src/index.ts"] }

bash "$ARRA/scripts/install-fleet-subagents.sh"
bash "$ARRA/scripts/install-inbox-loop-closure-hook.sh"
```

---

## Phase 9 — Smoke test  → [06-verify.md](06-verify.md)

```bash
curl -s http://localhost:47778/api/health | jq .
maw oracle ls
# In Claude Code: arra_search query="soul-brews-core" type=principle limit=5
```

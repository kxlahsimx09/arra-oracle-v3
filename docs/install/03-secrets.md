# 03 — Secrets Inventory

> **Rule:** secrets are referenced by **name only** in this document.
> Never write actual values into any doc, thread, envelope, commit, or retro.
> The central store (`~/.arra-oracle-v2/fleet-secrets/`) is the single
> source of truth. (AGENTS.md §3b)

---

## What Cannot Be Reconstructed

The following secrets are **not derivable from any API** and must be copied
from the old server or obtained from the human owner:

| Secret | Why it cannot be reconstructed |
|--------|-------------------------------|
| `ORACLE_SESSION_SECRET` (`.env`) | Random string; resets all sessions if changed |
| `supabase.env` DB password | Hosted Supabase DB credential; only the human can rotate it |
| `CLAUDE_CODE_OAUTH_TOKEN` (in `~/.claude.json`) | OAuth refresh token issued to a specific device |
| Telegram bot tokens (`BREW_OPS_BOT_TOKEN`, `TELEGRAM_BOT_TOKEN`) | Issued by BotFather; cannot be re-read after creation |

Copy these from the old server **before** decommissioning it:

```bash
# From the old server — run on OLD machine
tar czf /tmp/oracle-secrets-backup.tar.gz \
  ~/.arra-oracle-v2/fleet-secrets/ \
  ~/.cache/brew-ops-bot/.env \
  ~/.cache/orchestrator-bot/.env \
  ~/.claude.json

scp old-server:/tmp/oracle-secrets-backup.tar.gz ~/
```

```bash
# On the NEW machine
tar xzf ~/oracle-secrets-backup.tar.gz -C ~/
chmod 700 ~/.arra-oracle-v2/fleet-secrets
find ~/.arra-oracle-v2/fleet-secrets -name "*.env" -exec chmod 600 {} \;
```

---

## Secrets by Location

### `~/.arra-oracle-v2/fleet-secrets/<repo>/`  (chmod 700)

One directory per repo. Files inside are chmod 600.

| File | Key names | Used by |
|------|-----------|---------|
| `supabase.env` | `DATABASE_URL`, Supabase DB credentials | `bun run db:push`, mobiz migrations |

Worktree `.secrets` symlinks point here (auto-injected by maw at worktree
creation). The secrets never enter git.

---

### `~/.cache/brew-ops-bot/.env`

Read by `scripts/brew-ops-bot/bot.sh` at startup:

| Env var | Purpose |
|---------|---------|
| `BREW_OPS_BOT_TOKEN` | Telegram bot token for the brew-ops-bot |
| `BREW_OPS_BOT_CHAT` | Telegram chat ID to receive alerts |

Create the file:
```bash
mkdir -p ~/.cache/brew-ops-bot && chmod 700 ~/.cache/brew-ops-bot
cat > ~/.cache/brew-ops-bot/.env << 'EOF'
BREW_OPS_BOT_TOKEN=<token>
BREW_OPS_BOT_CHAT=<chat-id>
EOF
chmod 600 ~/.cache/brew-ops-bot/.env
```

---

### `~/.cache/orchestrator-bot/.env`

Read by `scripts/orchestrator-bot/bot.sh` at startup:

| Env var | Purpose |
|---------|---------|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token for `orchestrator-bot` |
| `TELEGRAM_CHAT_ID` | The orchestrator Telegram chat — hardcoded `2002026175` in bot.sh |

```bash
mkdir -p ~/.cache/orchestrator-bot && chmod 700 ~/.cache/orchestrator-bot
cat > ~/.cache/orchestrator-bot/.env << 'EOF'
TELEGRAM_BOT_TOKEN=<token>
TELEGRAM_CHAT_ID=2002026175
EOF
chmod 600 ~/.cache/orchestrator-bot/.env
```

---

### `~/.arra-oracle-v2/.env` / `arra-oracle-v3/.env`

Oracle server env (see `.env.example` for the full list):

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `PORT` | no | `47778` | Oracle HTTP port |
| `ORACLE_DATA_DIR` | yes | `~/.oracle` | Set to `~/.arra-oracle-v2` |
| `ORACLE_SESSION_SECRET` | recommended | auto-generated | Random string — keep stable |
| `ORACLE_VECTOR_DB` | no | `lancedb` | Options: `lancedb`, `chroma`, `qdrant` |
| `OLLAMA_BASE_URL` | no | `http://localhost:11434` | Embedding server |
| `OPENAI_API_KEY` | no | — | OpenAI embeddings (alternative to Ollama) |
| `CHROMA_URL` | no | `http://localhost:8000` | If using ChromaDB |
| `ORACLE_FORUM_REPO` | no | — | GitHub repo for forum sync |

---

### `~/.claude.json`

Contains engine credentials managed by Claude Code:

| Key | Purpose |
|-----|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | claude engine auth (per-device, cannot reconstruct) |
| `mcpServers` block | MCP server registrations including arra-oracle-v3 |

**Copy in full from the old server** — do not reconstruct from scratch.
After copying, update the `args` path for `arra-oracle-v3` if `$HOME` changed:

```bash
# Verify MCP path is correct
jq '.mcpServers["arra-oracle-v3"]' ~/.claude.json
# Should show: "command": "bun", "args": ["run", "/Users/<you>/Code/...arra-oracle-v3/src/index.ts"]
```

---

### `~/.ssh/id_ed25519` — regression-droplet access (easy to MISS)

`scripts/w2-watcher.sh` hardcodes `REGRESSION_HOST=${REGRESSION_HOST:-root@178.128.93.199}`
and **delegates the mobiz integration/regression suite to a remote DigitalOcean
droplet** (`temp-mb-regression-droplet`) — the host's own Docker is NOT used. The new
box's w2-watcher reaches it over SSH with the passphrase-less **`~/.ssh/id_ed25519`**.
Copy it or the W2 regression run fails with an SSH auth error:

```bash
scp old-box:~/.ssh/id_ed25519{,.pub} ~/.ssh/ && chmod 600 ~/.ssh/id_ed25519
ssh -i ~/.ssh/id_ed25519 root@178.128.93.199 'docker ps --format "{{.Names}}"'   # must connect
```
The droplet is **persistent + separate** (see the `temp-mb-regression-droplet` learning);
it stays put — only the SSH key moves with the fleet host.

---

## Verification

```bash
# All secrets files present?
ls -la ~/.cache/brew-ops-bot/.env
ls -la ~/.cache/orchestrator-bot/.env
ls -la ~/.arra-oracle-v2/fleet-secrets/

# Telegram bots alive?
TOKEN=$(grep BREW_OPS_BOT_TOKEN ~/.cache/brew-ops-bot/.env | cut -d= -f2)
curl -s "https://api.telegram.org/bot$TOKEN/getMe" | jq .ok
```

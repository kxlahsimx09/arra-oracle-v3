# 01 — OS Prerequisites & Dependencies

## macOS Version

macOS 13 (Ventura) or later. All launchd commands use the modern
`launchctl bootstrap / bootout / kickstart` API (requires macOS 10.12+).

---

## Homebrew + Core Tools

```bash
# Install Homebrew if absent
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install \
  git \
  tmux \
  ghq \
  gh \
  jq \
  curl \
  lsof \
  coreutils \
  pgrep    # bundled in proctools on macOS, or via coreutils
```

**Why each tool is required:**

| Tool | Required by |
|------|-------------|
| `git` | All repos, worktree management, ψ vault |
| `tmux` | maw agent sessions, chat-watcher pane delivery |
| `ghq` | Repo clone/locate — `ghq root` must return `$HOME/Code` |
| `gh` | PR creation, issue queries, silent-fail detection in w2-watcher |
| `jq` | Inbox-watcher JSON parsing, bot scripts |
| `lsof` | Inbox-watcher process liveness probe (`claude_alive_at`) |
| `pgrep` | Inbox-watcher agent PID tracking |
| `stat` | Inbox-watcher mtime inspection for JSONL recency |

---

## Bun ≥ 1.2

```bash
curl -fsSL https://bun.sh/install | bash
# Restart terminal or:
source "$HOME/.bashrc"    # bash
source "$HOME/.zshrc"     # zsh

bun --version   # must print 1.2.x or higher
```

**PATH** — the launchd plist (`com.soulbrews.inbox-watcher.plist`) hard-codes:
```
$HOME/.bun/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin
```
Bun must be installed at `$HOME/.bun/bin/bun` (default location) for the
launchd daemon to find it.

---

## Ollama + bge-m3 Embedder

Oracle defaults to LanceDB + Ollama (bge-m3) for vector embeddings.
ChromaDB is supported but optional — see note below.

```bash
brew install ollama
# Start Ollama service
brew services start ollama

# Pull the default embedding model
ollama pull bge-m3

# Verify (listening on :11434)
curl -s http://localhost:11434/api/tags | jq '.models[].name'
```

**OOM note:** Ollama's `bge-m3` requires ~600 MB RAM for the embedding model.
On a server with < 4 GB RAM, use `nomic-embed-text` (~250 MB) instead:
```bash
ollama pull nomic-embed-text
# In .env: ORACLE_EMBEDDING_MODEL=nomic-embed-text
```

---

## ChromaDB (optional)

ChromaDB is a Python-based vector store. Oracle falls back to LanceDB (the
default, embedded JS) if ChromaDB is unavailable. Only install if you need
the ChromaDB adapter explicitly.

```bash
pip3 install chromadb
# Run on port 8000
chroma run --host 0.0.0.0 --port 8000 &
```

**OOM note:** ChromaDB loads the entire embedding index into RAM. On servers
with < 2 GB RAM it can OOM and silently die. Monitor with:
```bash
pgrep -fl chroma && ps aux | grep chroma
```
Oracle handles ChromaDB absence gracefully by falling back to FTS5-only search.

---

## Agent Engines

### claude (CLAUDE_CODE_OAUTH_TOKEN)

```bash
# Install Claude Code CLI
npm install -g @anthropic-ai/claude-code    # or via brew / direct binary
claude --version
```

Authentication uses `CLAUDE_CODE_OAUTH_TOKEN`. This token is stored in
`~/.claude.json` and **cannot be reconstructed** — copy from the old server:
```bash
scp old-server:~/.claude.json ~/.claude.json
```

### codex (OPENAI_API_KEY)

```bash
npm install -g @openai/codex    # or equivalent
```

`OPENAI_API_KEY` goes in `~/.claude.json` under the project MCP block or as a
system env var. See [03-secrets.md](03-secrets.md) for the full secrets inventory.

---

## maw CLI

maw-js installs itself as `~/.local/bin/maw`. After cloning and building:

```bash
cd ~/Code/github.com/Soul-Brews-Studio/maw-js
git checkout feat/all-prs-rebased
bun install
# maw self-links during install; verify:
maw --version
```

`~/.local/bin` must be on `$PATH`. Add to `~/.bashrc` / `~/.zshrc` if absent:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

---

## sqlite3 CLI (optional, useful for migrations)

```bash
brew install sqlite
sqlite3 --version
```

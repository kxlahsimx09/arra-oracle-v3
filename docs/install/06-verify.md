# 06 — End-to-End Smoke Test & Verification

Run these checks in order after completing phases 0–8.
A ✓ on every item = the stack is healthy.

---

## Layer 1 — Processes

```bash
# Oracle HTTP
curl -s http://localhost:47778/api/health | jq .status
# → "ok"

# inbox-watcher
pgrep -fl "inbox-watcher.sh start"
# → one PID line

# maw
maw oracle ls
# → list of registered oracles including brew-ops

# w2-watcher
pgrep -fl "w2-watcher.sh"
# → one PID line (if started)

# bots
pgrep -fl "brew-ops-bot/bot.sh"
pgrep -fl "orchestrator-bot/bot.sh"
```

---

## Layer 2 — Oracle Database + Search

```bash
# Doc count
curl -s http://localhost:47778/api/stats | jq '{docs: .total, indexed: .indexed}'

# FTS5 search (no vectors needed)
curl -s 'http://localhost:47778/api/search?q=soul-brews-core&mode=fts' \
  | jq '.results | length'
# → > 0 (should find core principles)

# Hybrid search (requires Ollama running)
curl -s 'http://localhost:47778/api/search?q=soul-brews-core' \
  | jq '.results[0] | {title: .title, score: .score}'

# Swagger UI
open http://localhost:47778/swagger
```

---

## Layer 3 — MCP Server

Register oracle MCP in `~/.claude.json` if not already copied from old server:

```json
{
  "mcpServers": {
    "arra-oracle-v3": {
      "command": "bun",
      "args": ["run", "<HOME>/Code/github.com/Soul-Brews-Studio/arra-oracle-v3/src/index.ts"]
    }
  }
}
```

> **Use a literal absolute path.** Replace `<HOME>` with your actual home
> (`echo $HOME`, e.g. `/Users/admin`). MCP config loaders do **not** expand
> `$HOME`/`~`, so a tilde or env var here silently fails to resolve.

In a Claude Code session, verify:
```
arra_search query="soul-brews-core" type=principle limit=5
```
Expected: 4 principles returned (P-001 through P-004).

```
arra_stats
```
Expected: doc count, vector count, indexing status.

---

## Layer 4 — Symlinks

```bash
# .agent symlink chain
ls -la ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3/.agent
# → lrwxr-xr-x ... → .../mb_agent_oracle_memory/.../arra-oracle-v3/.agent

# ψ vault symlink
ls -la ~/.arra-oracle-v2/ψ
# → lrwxr-xr-x ... → .../mb_agent_oracle_memory/ψ

# ψ vault has memory content
ls ~/.arra-oracle-v2/ψ/memory/learnings/ | wc -l
# → > 0

# AGENTS.md readable
cat ~/.arra-oracle-v2/ψ/../github.com/Soul-Brews-Studio/arra-oracle-v3/.agent/AGENTS.md \
  | head -5
```

---

## Layer 5 — Inbox Protocol

```bash
# Inbox dirs exist
ls ~/.arra-oracle-v2/ψ/inbox/
# Expected: for-brew-ops/, for-orchestrator/, for-next-architect/, etc.

# inbox-watcher state dir
ls ~/.cache/inbox-watcher/state/ 2>/dev/null && echo "state dir present" \
  || echo "fresh (normal on new install)"

# Watcher log check (no ERROR lines)
grep -c ERROR ~/.cache/soul-brews-startup/inbox-watcher.launchd.log 2>/dev/null || true
```

---

## Layer 6 — maw + tmux Fleet

```bash
# maw working
maw --version
maw oracle ls        # should show brew-ops, next-architect, etc.

# tmux session
tmux ls 2>/dev/null || echo "no sessions — start with: tmux new-session -s soul-brews"

# Wake brew-ops (will open a tmux pane)
# maw wake brew-ops
```

---

## Layer 7 — Fleet Sub-Agents

```bash
ls ~/.claude/agents/
# Expected: code-finder.md  dpay-finder.md

# Reinstall if missing
bash ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3/scripts/install-fleet-subagents.sh
```

---

## Layer 8 — Hooks

```bash
# Loop-closure hook installed
grep -l "inbox-loop-closure" ~/.claude/settings.json 2>/dev/null && echo "✓ hook present"

# Orchestrator guard installed
grep -l "orchestrator-guard" ~/.claude/settings.json 2>/dev/null && echo "✓ guard present"
```

---

## Full Checklist Summary

```
[ ] Oracle HTTP :47778 returns { "status": "ok" }
[ ] inbox-watcher running under launchd (pgrep confirms)
[ ] SQLite oracle.db has docs (stats > 0)
[ ] FTS5 search returns results for "soul-brews-core"
[ ] Vector search returns results (Ollama :11434 reachable)
[ ] MCP arra_search returns 4 principles in Claude Code
[ ] .agent symlink → mb_agent_oracle_memory
[ ] ψ symlink → mb_agent_oracle_memory/ψ
[ ] Inbox dirs present under ψ/inbox/for-*/
[ ] Telegram bots responding (send /help)
[ ] maw oracle ls shows expected roles
[ ] ~/.claude/agents/ has code-finder + dpay-finder
[ ] Claude Code Stop hook (inbox-loop-closure) installed
[ ] Primary checkouts on feat/all-prs-rebased (arra-oracle-v3, maw-js)
```

---

## Troubleshooting Quick Reference

| Symptom | First check |
|---------|-------------|
| inbox-watcher not running | `tail ~/.cache/soul-brews-startup/inbox-watcher.launchd.log` |
| Search returns 0 results | Run `bun run reindex:full` in arra-oracle-v3 |
| MCP not found in Claude Code | Check `jq '.mcpServers' ~/.claude.json` |
| bot says "env missing" | Check `~/.cache/brew-ops-bot/.env` permissions (chmod 600) |
| chat-watcher silent | Check `JSONL_WAIT_SECONDS` in chat-watcher.sh (must be 480) |
| Vectors missing after migrate | Ollama not running — `brew services start ollama` |
| `.agent` is a real dir not symlink | `rm -r <repo>/.agent && ln -sfn ... <repo>/.agent` |

# 04 — Data Migration

Three data stores must be migrated:

1. **Oracle SQLite DB** (`~/.arra-oracle-v2/oracle.db`) — knowledge index
2. **LanceDB vectors** (`~/.arra-oracle-v2/lancedb/`) — embedding index
3. **ψ vault** (`mb_agent_oracle_memory/ψ/`) — git-tracked markdown vault

---

## 1. Oracle SQLite

The SQLite database lives at `$ORACLE_DATA_DIR/oracle.db`
(default: `~/.arra-oracle-v2/oracle.db`).

### Migrate via rsync

```bash
# Stop oracle HTTP server first (avoid WAL corruption)
pkill -f "bun src/server.ts" || true
sleep 2

# Sync data dir from old server
rsync -a --progress \
  old-server:~/.arra-oracle-v2/oracle.db \
  ~/.arra-oracle-v2/oracle.db
```

### Schema migrations (Drizzle)

On the new server, after copy, run schema push to apply any pending migrations:

```bash
cd ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
ORACLE_DATA_DIR=~/.arra-oracle-v2 bun run db:push
```

**Safety rule:** never modify the SQLite schema outside Drizzle.
Direct `ALTER TABLE` / `CREATE INDEX` bypasses Drizzle's state tracking.
If schema drift is suspected, update `src/db/schema.ts` first, then `db:push`.

### Verify

```bash
sqlite3 ~/.arra-oracle-v2/oracle.db \
  "SELECT COUNT(*) as docs FROM oracle_documents; \
   SELECT is_indexing, progress_current, progress_total FROM indexing_status;"
```

---

## 2. LanceDB Vectors

LanceDB is an embedded JS store — data lives in files at
`~/.arra-oracle-v2/lancedb/` (auto-derived from `ORACLE_DATA_DIR`).

### Migrate

```bash
rsync -a --progress \
  old-server:~/.arra-oracle-v2/lancedb/ \
  ~/.arra-oracle-v2/lancedb/
```

### Reindex (if migrating across embedding models or after vector drift)

If Ollama model changed or the vector index seems stale, run a full reindex:

```bash
cd ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
ORACLE_REPO_ROOT=~/Code/github.com/kxlahsimx09/mb_agent_oracle_memory \
  ORACLE_DATA_DIR=~/.arra-oracle-v2 bun run reindex:full
```

> **⚠️ Set `ORACLE_REPO_ROOT` to the vault repo, not the data dir.** Learnings
> are stored **project-first** — most live under
> `mb_agent_oracle_memory/github.com/<owner>/<repo>/ψ/memory/learnings/`, not in
> the central `ψ/`. The indexer's `discoverProjectPsiDirs()` only finds them if
> `ORACLE_REPO_ROOT` points at the repo root that has the `github.com/` tree
> beside `ψ/`. If you let it default to `~/.arra-oracle-v2` (which only holds the
> `ψ` symlink, no sibling `github.com/`), it silently indexes **only the ~98
> central learnings and drops ~860 per-repo ones**. Also run from a checkout that
> has the `_universal/ψ` discovery fix (commit `78933e3` or later) so the
> `_universal` bucket isn't skipped too.

`reindex:full` runs `src/indexer/cli.ts` then `src/scripts/index-model.ts bge-m3`.
The vector step embeds every doc via Ollama `bge-m3` (~0.8 doc/s → ~80 min for a
~4,300-doc vault). It calls `deleteCollection()` first, so **back up
`lancedb/oracle_knowledge_bge_m3.lance/` before running** if you need search to
stay available during the rebuild. Never run two `index-model.ts` at once —
concurrent LanceDB writers corrupt the collection. Verify with:

```bash
# total docs + per-model vector counts (bge-m3 should match total)
curl -s http://localhost:47778/api/stats \
  | jq '{docs: .total, bge_m3: (.vectors[] | select(.key=="bge-m3") | .count)}'

# per-type breakdown — learning count should be in the ~950+ file range,
# NOT ~98. A learning count near 98 means the repoRoot trap above bit you.
curl -s http://localhost:47778/api/stats | jq '.by_type_files'
```

---

## 3. ψ Vault (git-tracked markdown)

The vault is the `ψ/` directory inside `mb_agent_oracle_memory`. It is
git-tracked, so migration = `git fetch + merge`.

```bash
cd ~/Code/github.com/kxlahsimx09/mb_agent_oracle_memory
git fetch --all
git merge --ff-only origin/main
```

Verify the symlink resolves:
```bash
ls ~/.arra-oracle-v2/ψ/memory/learnings/ | head -5
```

### Full rsync sync (first-time bulk transfer)

If the git clone is fresh and the vault is large, an rsync first-pass from the
old server is faster than cloning full history:

```bash
rsync -a --exclude='.git' \
  old-server:~/Code/github.com/kxlahsimx09/mb_agent_oracle_memory/ψ/ \
  ~/Code/github.com/kxlahsimx09/mb_agent_oracle_memory/ψ/
```

Then `git fetch && git merge --ff-only` to bring the git index up to date.

---

## 4. Watcher State (optional — can be left fresh)

Inbox-watcher and w2-watcher state is in `~/.cache/inbox-watcher/` and
`~/.cache/w2-watcher/`. These are ephemeral operational state (not vault) and
**can be started fresh** on a new server — the state machine will re-scan
in-flight envelopes and re-derive state from the vault.

If you want continuity across the migration (avoid re-firing envelopes):

```bash
rsync -a old-server:~/.cache/inbox-watcher/ ~/.cache/inbox-watcher/
rsync -a old-server:~/.cache/w2-watcher/    ~/.cache/w2-watcher/
```

---

## 5. Post-migration Checklist

```bash
# 1. DB schema current
bun run db:push --cwd ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3

# 2. Vault synced and symlink live
ls ~/.arra-oracle-v2/ψ/memory/ | head

# 3. Oracle HTTP can read docs
curl -s http://localhost:47778/api/stats | jq .

# 4. Search smoke test
curl -s 'http://localhost:47778/api/search?q=soul-brews-core' | jq '.results | length'
```

If the search returns 0 after migration, run reindex:
```bash
bun run reindex:full --cwd ~/Code/github.com/Soul-Brews-Studio/arra-oracle-v3
```

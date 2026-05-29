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
ORACLE_DATA_DIR=~/.arra-oracle-v2 bun run reindex:full
```

`reindex:full` runs `src/indexer/cli.ts` then `src/scripts/index-model.ts bge-m3`.
This can take several minutes on a large vault. Verify with:

```bash
curl -s http://localhost:47778/api/stats | jq '{docs: .total, vectors: .vectors}'
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

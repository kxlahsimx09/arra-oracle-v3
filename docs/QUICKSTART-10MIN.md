# 10-minute quickstart verification

Live check for #2420: start Oracle, mine a small folder, then search for the
mined note. This run used the local server path allowed by the issue instead of
Docker.

## Commands verified

From a clean checkout:

```bash
export ORACLE_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/arra-quickstart-XXXXXX")"
export ORACLE_DB_PATH="$ORACLE_DATA_DIR/oracle.db"
export ORACLE_PORT=48942
export PORT="$ORACLE_PORT"
export ORACLE_FILE_WATCHER=0

bun bin/arra.ts serve --port "$ORACLE_PORT"
```

In another shell, mine with the same package bin. In an installed build this is
`arra-oracle mine`; in this source checkout the same entrypoint is
`bun bin/arra.ts mine`:

```bash
bun bin/arra.ts mine docs/sample-notes --db-path "$ORACLE_DB_PATH"
curl -s "http://127.0.0.1:$ORACLE_PORT/api/v1/search?q=memory%20onboarding&mode=fts&limit=5"
```

## Actual elapsed run

Verified on 2026-06-17 from branch `origin/alpha` using `rtk`:

| Elapsed | Step | Evidence |
| ---: | --- | --- |
| 0.02s | Created isolated data dir | `ORACLE_DATA_DIR=/var/.../arra-quickstart-bin-aIVoDF` |
| 0.04s | Started local server | `bun bin/arra.ts serve --port 48942`, PID `16156`, port `48942` |
| 0.61s | Health check passed | `GET /api/health` returned OK |
| 0.63s | Mined sample folder | `Mined 2 documents from 2 files (0 skipped)` |
| 0.71s | Searched indexed notes | `GET /api/v1/search?q=memory%20onboarding&mode=fts&limit=5` |
| 0.76s | Verified result | response included `mine/sample-notes/projects/oracle-memory.md` |
| 0.78s | Complete | end-to-end under one second on this machine |

Search response summary:

```json
{
  "status": 200,
  "total": 2,
  "sources": [
    "mine/sample-notes/ops/runbook.txt",
    "mine/sample-notes/projects/oracle-memory.md"
  ]
}
```

## Notes

- No schema, vector-provider, or taxonomy choices were required.
- Vector indexing was skipped by default-safe FTS mode: `Skipping vector indexing (SQLite-only mode)`.
- Re-running `arra mine docs/sample-notes` is safe; unchanged files are skipped.

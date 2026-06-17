# Benchmark Results

## Public-style honest recall run (#2420 / #2425)

Run date: 2026-06-17

Harness: `benchmarks/honest-recall.ts` (`runHonestRecallBenchmark`) against the real `/api/search` HTTP surface backed by a temporary SQLite/FTS5 database seeded with a 12-document public-style corpus.

Result: **Recall@3 = 0.75** (`6/8` queries hit at least one expected document in the top 3).

Answer accuracy was **not measured**; this harness is retrieval-only and does not run an answer generator or judge.

### Provenance JSON

```json
{
  "mode": "fts",
  "model": "multi",
  "top_k": 3,
  "corpus": {
    "label": "public-style-12-docs-inline-v1",
    "size": 12
  },
  "metric": "Recall@k",
  "git-sha": "ede1301ec800d3726e848a0faf1ab51b6d4cb22a",
  "stack": ["multi", "fts"]
}
```

### Query cases

| Case | Expected | Retrieved top IDs | Hit | Rank |
| --- | --- | --- | --- | --- |
| `exact/backup-restore` | `pub-doc-002` | `pub-doc-002`, `pub-doc-006` | yes | 1 |
| `exact/tenant-isolation` | `pub-doc-005` | `pub-doc-005` | yes | 1 |
| `exact/supersede-chain` | `pub-doc-007` | `pub-doc-004`, `pub-doc-007` | yes | 2 |
| `exact/fts5-token` | `pub-doc-003` | `pub-doc-003` | yes | 1 |
| `exact/canvas-plugin` | `pub-doc-012` | `pub-doc-010`, `pub-doc-012` | yes | 2 |
| `weak/semantic-vector` | `pub-doc-004` | `pub-doc-010`, `pub-doc-003` | no | - |
| `weak/acronym-only` | `pub-doc-009` | `pub-doc-002` | no | - |
| `weak/paraphrase-taxonomy` | `pub-doc-008` | `pub-doc-008`, `pub-doc-007`, `pub-doc-011` | yes | 1 |

Weak categories were intentionally included. The FTS-only run missed semantic/vector-style paraphrase and acronym-only accessibility queries, so the reported Recall@3 is not inflated by dropping weak cases.

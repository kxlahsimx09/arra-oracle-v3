# Benchmark Results

## Honest retrieval methodology (#2472)

Run date: 2026-06-17

Harness: `benchmarks/honest-recall.ts` (`runHonestRecallBenchmark`) against the temp backend in `benchmarks/hybrid-temp-backend.ts`. The runner starts an in-memory Bun `/api/search` service, seeds a 12-document public corpus into SQLite FTS5 plus memory vectors, embeds those same 12 docs through local Ollama (`bge-m3`, `nomic-embed-text`, `qwen3-embedding`), and writes `benchmarks/out/honest-recall.json`.

Answer accuracy is **not measured**. The retrieval methodology is two-track:

| Track | Denominator | Success | Reported fields |
| --- | --- | --- | --- |
| Recall@k | answerable queries with non-empty `expectedIds` | at least one expected doc in top-k | `hits / total_queries` |
| Reject-Recall | unanswerable controls with empty `expectedIds` | retriever returns no docs | `correct_rejections / total_unanswerable` |
| Reject-Precision | all no-result responses | no-result response belongs to an unanswerable query | `correct_rejections / total_rejections` |

Empty-`expectedIds` controls leave the Recall@k denominator and are scored only as correct rejection, matching the PhotoBench/trec_eval pattern.

## Current temp-backed run

| Run | Backend | Model / stack | Corpus | Answerable Recall@3 | Reject metrics | Weak cases disclosed |
| --- | --- | --- | --- | --- | --- | --- |
| FTS baseline | temp SQLite FTS5 | FTS5 only | `temp-ollama-12-docs-v1` | 9/10 = 0.9 | none in 10-query seed | Missed `weak/semantic-vector`; no vector evidence used. |
| Hybrid headline | temp FTS5 + memory vectors | `multi` = bge-m3 + nomic + qwen3 + FTS5 | `temp-ollama-12-docs-v1` | 10/10 = 1 | none in 10-query seed | Recovered all bounded seed queries. |

### Reproduce

```bash
bun run benchmarks/hybrid-temp-backend.ts \
  --out benchmarks/out/honest-recall.json
```

The command requires local Ollama embedding models `bge-m3`, `nomic-embed-text`, and `qwen3-embedding`. It seeds only the temp 12-doc corpus and avoids live-vault reindexing. The headline only claims retrieval metrics for this bounded corpus; it does not claim live-vault health or answer accuracy.

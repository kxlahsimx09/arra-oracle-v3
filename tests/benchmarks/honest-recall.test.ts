import { afterEach, describe, expect, test } from 'bun:test';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  createHttpSearcher,
  guardTopK,
  parseDatasetText,
  runHonestRecallBenchmark,
  type Searcher,
} from '../../benchmarks/honest-recall.ts';

const roots: string[] = [];

function tempFile(name: string): string {
  const root = mkdtempSync(join(tmpdir(), 'arra-honest-bench-'));
  roots.push(root);
  return join(root, name);
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe('honest recall benchmark harness', () => {
  test('refuses to report Recall@k when top_k covers the corpus', async () => {
    const outFile = tempFile('refused.json');
    expect(() => guardTopK(4, 4)).toThrow('Refusing to report Recall@4');
    expect(() => guardTopK(5, 4)).toThrow('top_k (5) must be smaller than corpus_size (4)');
    const searcher: Searcher = async () => { throw new Error('searcher should not run'); };

    await expect(runHonestRecallBenchmark({
      cases: [{ id: 'q1', query: 'alpha', expectedIds: ['doc-a'] }],
      corpus: { label: 'tiny', size: 4 },
      topK: 4,
      searcher,
      outFile,
      gitSha: 'abc123',
    })).rejects.toThrow('top_k (4) must be smaller than corpus_size (4)');
    expect(existsSync(outFile)).toBe(false);
  });

  test('writes provenance JSON and separates Recall@k from Answer-Accuracy', async () => {
    const outFile = tempFile('report.json');
    const searcher: Searcher = async ({ query }) => query === 'alpha'
      ? [{ id: 'noise' }, { id: 'doc-a' }]
      : [{ id: 'noise' }, { id: 'other' }];

    const report = await runHonestRecallBenchmark({
      cases: parseDatasetText([
        JSON.stringify({ id: 'q1', query: 'alpha', expected_ids: ['doc-a'], answer: 'A' }),
        JSON.stringify({ id: 'q2', query: 'beta', relevant_ids: ['doc-b'], answer: 'B' }),
      ].join('\n')),
      corpus: { label: 'oracle-test', size: 10 },
      topK: 3,
      searcher,
      outFile,
      gitSha: 'abc123',
      now: '2026-06-17T00:00:00.000Z',
    });

    expect(report.provenance).toMatchObject({ mode: 'hybrid', model: 'multi', top_k: 3, metric: 'Recall@3', metric_family: 'Recall@k', 'git-sha': 'abc123' });
    expect(report.provenance.stack).toEqual(['bge-m3', 'nomic', 'qwen3', 'FTS5']);
    expect(report.metrics[0]).toMatchObject({ metric: 'Recall@3', metric_family: 'Recall@k', label: 'Recall@3', value: 0.5, hits: 1, total_queries: 2 });
    expect(report.metrics[1]).toMatchObject({ metric: 'Answer-Accuracy', metric_family: 'Answer-Accuracy', status: 'not-measured' });
    expect('value' in report.metrics[1]).toBe(false);
    expect(report.cases.map((item) => item.metric)).toEqual(['Recall@3', 'Recall@3']);
    expect(report.cases.map((item) => item.metric_family)).toEqual(['Recall@k', 'Recall@k']);
    expect(JSON.parse(readFileSync(outFile, 'utf8')).provenance.corpus).toEqual({ label: 'oracle-test', size: 10 });
  });

  test('rejects invalid mode before search or provenance output', async () => {
    const outFile = tempFile('bad-mode.json');
    const searcher: Searcher = async () => { throw new Error('searcher should not run'); };

    await expect(runHonestRecallBenchmark({
      cases: [{ id: 'q1', query: 'alpha', expectedIds: ['doc-a'] }],
      corpus: { label: 'oracle-test', size: 10 },
      topK: 3,
      mode: 'fake' as never,
      searcher,
      outFile,
      gitSha: 'abc123',
    })).rejects.toThrow('mode must be one of: hybrid, fts, vector');
    expect(existsSync(outFile)).toBe(false);
  });

  test('HTTP searcher calls our hybrid multi-model search surface', async () => {
    const seen: string[] = [];
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch(request) {
        const url = new URL(request.url);
        seen.push(url.searchParams.toString());
        return Response.json({ results: [{ id: 'doc-a', source_file: 'vault/a.md' }] });
      },
    });
    try {
      const hits = await createHttpSearcher(`http://127.0.0.1:${server.port}`)({ query: 'needle', topK: 7, mode: 'hybrid', model: 'multi' });
      expect(hits).toEqual([{ id: 'doc-a', source_file: 'vault/a.md', sourceFile: '' }]);
      expect(seen[0]).toContain('q=needle');
      expect(seen[0]).toContain('limit=7');
      expect(seen[0]).toContain('mode=hybrid');
      expect(seen[0]).toContain('model=multi');
    } finally {
      await server.stop(true);
    }
  });
});

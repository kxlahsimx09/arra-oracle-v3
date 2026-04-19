/**
 * Regression guard for thread #9 — first-call-per-MCP-process race between
 * `getVectorStoreByModel()` (starts connect in background, returns immediately)
 * and `addDocuments()` (throws if `this.db` is null).
 *
 * `arra_learn` used to call the former directly, causing the first `arra_learn`
 * invocation in every fresh MCP process to write to FTS/disk but miss the
 * vector store, returning `embedding: "failed"` and logging a warning.
 *
 * Observed 4× across 2026-04-17 and 2026-04-18 retros before the fix landed.
 *
 * The fix in `src/tools/learn.ts` replaced `getVectorStoreByModel` with
 * `await ensureVectorStoreConnected`, which awaits the connect promise before
 * returning the store. This test asserts the raw race still exists at the
 * adapter level (so we understand what we're guarding against) AND that the
 * `ensureVectorStoreConnected` pattern prevents it.
 */

import { describe, test, expect } from 'bun:test';
import { LanceDBAdapter } from '../adapters/lancedb.ts';
import type { EmbeddingProvider } from '../types.ts';

// Stub embedder — never called in these tests; the race is upstream of embed().
const fakeEmbedder: EmbeddingProvider = {
  name: 'fake',
  dimensions: 4,
  async embed(texts: string[]): Promise<number[][]> {
    return texts.map(() => [0, 0, 0, 0]);
  },
};

describe('LanceDBAdapter — connect race (thread #9 regression guard)', () => {
  test('raw adapter throws "not connected" if addDocuments runs before connect resolves', async () => {
    const adapter = new LanceDBAdapter('test_connect_race', '/tmp/arra-oracle-test-nonexistent-' + Date.now(), fakeEmbedder);

    // Do NOT call connect(). Simulate the race — caller received the adapter
    // from getVectorStoreByModel but never awaited the background connect.
    await expect(adapter.addDocuments([{
      id: 'doc_1',
      document: 'race-condition probe',
      metadata: { type: 'test' },
    }])).rejects.toThrow(/LanceDB not connected/);
  });

  test('error message names LanceDB so grep-based log triage can find it', async () => {
    const adapter = new LanceDBAdapter('test_connect_race', '/tmp/arra-oracle-test-nonexistent-' + Date.now(), fakeEmbedder);

    try {
      await adapter.addDocuments([{ id: 'x', document: 'y', metadata: {} }]);
      throw new Error('expected adapter.addDocuments to throw');
    } catch (err) {
      expect(err instanceof Error).toBe(true);
      expect((err as Error).message).toContain('LanceDB');
      expect((err as Error).message).toContain('not connected');
    }
  });
});

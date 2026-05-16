/**
 * thread #113 — LanceDB manifest-drift resilience.
 *
 * Two behaviors, both mocked (no real @lancedb/lancedb — not installed in
 * agent worktrees, and connect() imports it lazily so the class is safe to
 * construct):
 *   - addDocuments() serializes concurrent in-process writes so two callers
 *     cannot interleave a manifest version.
 *   - health() runs a real search() probe so a drifted manifest (countRows
 *     still answers, search() throws) is reported as degraded.
 */

import { describe, it, expect } from 'bun:test';
import { LanceDBAdapter } from '../adapters/lancedb.ts';
import type { EmbeddingProvider } from '../types.ts';

const fakeEmbedder: EmbeddingProvider = {
  name: 'fake',
  dimensions: 4,
  embed: async (texts) => texts.map(() => [0, 0, 0, 0]),
};

function makeAdapter(): LanceDBAdapter {
  return new LanceDBAdapter('test_coll', '/tmp/arra-nonexistent', fakeEmbedder);
}

const doc = (id: string) => ({ id, document: 't', metadata: {}, vector: [0, 0, 0, 0] });

describe('LanceDBAdapter — in-process write serialization', () => {
  it('serializes concurrent addDocuments calls (no interleaving)', async () => {
    const events: string[] = [];
    let inFlight = 0;
    const adapter = makeAdapter();
    (adapter as any).table = {
      add: async (rows: any[]) => {
        inFlight++;
        expect(inFlight).toBe(1); // never two table.add() at once
        events.push(`start:${rows[0].id}`);
        await new Promise((r) => setTimeout(r, 15));
        events.push(`end:${rows[0].id}`);
        inFlight--;
      },
    };

    await Promise.all([
      adapter.addDocuments([doc('A')]),
      adapter.addDocuments([doc('B')]),
      adapter.addDocuments([doc('C')]),
    ]);

    expect(events).toEqual([
      'start:A', 'end:A',
      'start:B', 'end:B',
      'start:C', 'end:C',
    ]);
  });

  it('a rejected write does not wedge the chain', async () => {
    let calls = 0;
    const adapter = makeAdapter();
    (adapter as any).table = {
      add: async () => {
        calls++;
        if (calls === 1) throw new Error('boom');
      },
    };

    await expect(adapter.addDocuments([doc('A')])).rejects.toThrow('boom');
    // The next write still runs despite the prior one rejecting.
    await adapter.addDocuments([doc('B')]);
    expect(calls).toBe(2);
  });
});

describe('LanceDBAdapter.health — active probe', () => {
  const searchChain = (toArray: () => Promise<any[]>) => ({
    search: () => ({ distanceType: () => ({ limit: () => ({ toArray }) }) }),
    countRows: async () => 42,
  });

  it('reports ok + count when the probe query succeeds', async () => {
    const adapter = makeAdapter();
    (adapter as any).table = searchChain(async () => []);
    const h = await adapter.health();
    expect(h.ok).toBe(true);
    expect(h.count).toBe(42);
    expect(h.error).toBeUndefined();
  });

  it('reports degraded + error when search() throws (manifest drift)', async () => {
    const adapter = makeAdapter();
    (adapter as any).table = searchChain(async () => {
      throw new Error('lance error: Not found: oracle_knowledge_bge_m3.lance/data/abc.lance');
    });
    const h = await adapter.health();
    expect(h.ok).toBe(false);
    expect(h.error).toContain('Not found');
    expect(h.count).toBeUndefined();
  });
});

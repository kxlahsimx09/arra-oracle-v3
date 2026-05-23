/**
 * thread #115 Phase 2 — LanceDBAdapter routes manifest-mutating writes through
 * the inter-process file lock. Phase 1's writeChain only serializes writes
 * within ONE adapter instance; the root cause is concurrent writes from
 * SEPARATE processes sharing one lancedb dir. Two adapter instances pointing at
 * the same dir + collection stand in for two processes here: their table.add()
 * calls must not overlap, proving the file lock (not writeChain) does the work.
 */
import { describe, it, expect, afterEach } from 'bun:test';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { randomUUID } from 'crypto';
import { LanceDBAdapter } from '../lancedb.ts';
import type { EmbeddingProvider } from '../../types.ts';

const fakeEmbedder: EmbeddingProvider = {
  name: 'fake',
  dimensions: 4,
  embed: async (texts) => texts.map(() => [0, 0, 0, 0]),
};
const doc = (id: string) => ({ id, document: 't', metadata: {} });

let lastLockRoot: string | null = null;
afterEach(async () => {
  if (lastLockRoot) await fs.promises.rm(lastLockRoot, { recursive: true }).catch(() => {});
  lastLockRoot = null;
});

describe('LanceDBAdapter — inter-process write lock', () => {
  it('two instances on the same dir never run table.add concurrently', async () => {
    const dir = path.join(os.tmpdir(), `arra-ipc-${randomUUID()}`);
    lastLockRoot = `${dir}.write-locks`;
    const a1 = new LanceDBAdapter('coll', dir, fakeEmbedder);
    const a2 = new LanceDBAdapter('coll', dir, fakeEmbedder);

    let inFlight = 0;
    const events: string[] = [];
    const mkTable = (tag: string) => ({
      add: async () => {
        inFlight++;
        expect(inFlight).toBe(1); // the lock guarantees one writer at a time
        events.push(`s${tag}`);
        await new Promise((r) => setTimeout(r, 30));
        events.push(`e${tag}`);
        inFlight--;
      },
    });
    (a1 as any).table = mkTable('1');
    (a2 as any).table = mkTable('2');

    await Promise.all([a1.addDocuments([doc('A')]), a2.addDocuments([doc('B')])]);

    expect(events.filter((e) => e.startsWith('s')).length).toBe(2); // both wrote
    expect(events.length).toBe(4); // and each fully completed (s,e ×2)
  });

  it('separate collections do not block each other (per-collection keying)', async () => {
    const dir = path.join(os.tmpdir(), `arra-ipc-${randomUUID()}`);
    lastLockRoot = `${dir}.write-locks`;
    const bge = new LanceDBAdapter('bge', dir, fakeEmbedder);
    const qwen = new LanceDBAdapter('qwen', dir, fakeEmbedder);

    let overlap = 0;
    let maxOverlap = 0;
    const mkTable = () => ({
      add: async () => {
        overlap++;
        maxOverlap = Math.max(maxOverlap, overlap);
        await new Promise((r) => setTimeout(r, 30));
        overlap--;
      },
    });
    (bge as any).table = mkTable();
    (qwen as any).table = mkTable();

    await Promise.all([bge.addDocuments([doc('A')]), qwen.addDocuments([doc('B')])]);

    // Different lock files ⇒ the two writes are allowed to overlap.
    expect(maxOverlap).toBe(2);
  });
});

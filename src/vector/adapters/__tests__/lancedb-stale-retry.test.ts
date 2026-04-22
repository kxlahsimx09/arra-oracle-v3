/**
 * LanceDBAdapter stale-snapshot retry unit tests.
 *
 * A reindex (compaction + GC) that runs while this process holds an open
 * LanceDB connection leaves the cached snapshot pointing at fragment files
 * that no longer exist on disk. Subsequent reads surface as
 * `lance error: Not found: ....lance`. These tests verify that query paths
 * detect the error, reopen the connection, and retry once.
 */

import { describe, test, expect } from 'bun:test';
import { LanceDBAdapter } from '../lancedb.ts';
import type { EmbeddingProvider } from '../../types.ts';

const fakeEmbedder: EmbeddingProvider = {
  model: 'test-embed',
  dimensions: 3,
  embed: async (texts: string[]) => texts.map(() => [0, 0, 0]),
};

type FakeTable = {
  search: (v: any) => { limit: (n: number) => { toArray: () => Promise<any[]> } };
  query: () => { where: (w: string) => { limit: (n: number) => { toArray: () => Promise<any[]> } }; limit: (n: number) => { toArray: () => Promise<any[]> } };
  countRows: () => Promise<number>;
};

function makeTableThatThrowsThenSucceeds(failures: number, successRows: any[]): { table: FakeTable; calls: { value: number } } {
  const calls = { value: 0 };
  const err = new Error('lance error: Not found: /Users/x/.arra-oracle-v2/lancedb/foo.lance/data/aabb.lance, /Users/runner/.cargo/.../lance-io-4.0.0/src/local.rs:132:40');
  const toArray = async () => {
    calls.value++;
    if (calls.value <= failures) throw err;
    return successRows;
  };
  const countRows = async () => {
    calls.value++;
    if (calls.value <= failures) throw err;
    return successRows.length;
  };
  const table: FakeTable = {
    search: () => ({ limit: () => ({ toArray }) }),
    query: () => ({
      where: () => ({ limit: () => ({ toArray }) }),
      limit: () => ({ toArray }),
    }),
    countRows,
  };
  return { table, calls };
}

function installTable(adapter: LanceDBAdapter, table: FakeTable): void {
  // Stub all connection paths to avoid loading @lancedb/lancedb at all.
  // The retry logic resets `this.db`/`this.table` to null and calls connect()
  // + ensureCollection() — override both so the fake table survives reopen.
  const a = adapter as any;
  const fakeDb = { tableNames: async () => ['test'], openTable: async () => table };
  a.db = fakeDb;
  a.table = table;
  a.connect = async () => { a.db = fakeDb; };
  a.ensureCollection = async () => { a.table = table; };
}

describe('LanceDBAdapter stale-snapshot retry', () => {
  test('query() retries once on stale-snapshot error and succeeds', async () => {
    const adapter = new LanceDBAdapter('test', '/tmp/nope', fakeEmbedder);
    const successRows = [{ id: 'doc_1', text: 'hi', metadata: '{}', _distance: 0.1 }];
    const { table, calls } = makeTableThatThrowsThenSucceeds(1, successRows);
    installTable(adapter, table);

    const result = await adapter.query('hello', 5);

    expect(calls.value).toBe(2); // first throw + one retry
    expect(result.ids).toEqual(['doc_1']);
  });

  test('query() does NOT retry on unrelated errors', async () => {
    const adapter = new LanceDBAdapter('test', '/tmp/nope', fakeEmbedder);
    const calls = { value: 0 };
    const unrelatedErr = new Error('network timeout');
    const table: FakeTable = {
      search: () => ({ limit: () => ({ toArray: async () => { calls.value++; throw unrelatedErr; } }) }),
      query: () => ({ where: () => ({ limit: () => ({ toArray: async () => [] }) }), limit: () => ({ toArray: async () => [] }) }),
      countRows: async () => 0,
    };
    installTable(adapter, table);

    await expect(adapter.query('hi', 5)).rejects.toThrow('network timeout');
    expect(calls.value).toBe(1); // no retry
  });

  test('query() re-throws if retry also fails', async () => {
    const adapter = new LanceDBAdapter('test', '/tmp/nope', fakeEmbedder);
    const { table, calls } = makeTableThatThrowsThenSucceeds(5, []); // always throws
    installTable(adapter, table);

    await expect(adapter.query('hi', 5)).rejects.toThrow(/lance error.*Not found/);
    expect(calls.value).toBe(2); // one attempt + one retry, then give up
  });

  test('getStats() retries once on stale-snapshot error', async () => {
    const adapter = new LanceDBAdapter('test', '/tmp/nope', fakeEmbedder);
    const { table, calls } = makeTableThatThrowsThenSucceeds(1, [{}, {}, {}]);
    installTable(adapter, table);

    const stats = await adapter.getStats();
    expect(calls.value).toBe(2);
    expect(stats.count).toBe(3);
  });
});

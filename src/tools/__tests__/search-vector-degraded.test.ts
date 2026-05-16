/**
 * thread #113 — arra_search must not hide a degraded vector backend.
 *
 * vectorSearch() used to catch every error and return [] — making a drifted
 * LanceDB manifest indistinguishable from a genuine zero-result query. Every
 * search silently fell back to FTS5. Now the error propagates: handleSearch
 * sets a real warning and metadata.vectorDegraded = true.
 */

import { describe, it, expect } from 'bun:test';
import Database from 'bun:sqlite';
import { drizzle } from 'drizzle-orm/bun-sqlite';
import * as schema from '../../db/schema.ts';
import { handleSearch } from '../search.ts';
import type { ToolContext } from '../types.ts';

const SCHEMA = `
CREATE TABLE oracle_documents (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  source_file TEXT NOT NULL,
  concepts TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  indexed_at INTEGER NOT NULL,
  superseded_by TEXT,
  superseded_at INTEGER,
  superseded_reason TEXT,
  origin TEXT,
  project TEXT,
  created_by TEXT
);
CREATE VIRTUAL TABLE oracle_fts USING fts5(id UNINDEXED, content, concepts, tokenize='porter unicode61');
`;

const EMPTY_RESULT = { ids: [], documents: [], distances: [], metadatas: [] };

function makeCtx(query: () => Promise<unknown>): ToolContext {
  const sqlite = new Database(':memory:');
  sqlite.exec(SCHEMA);
  const db = drizzle(sqlite, { schema });
  return {
    db,
    sqlite,
    repoRoot: '/tmp',
    vectorStore: { query } as unknown as ToolContext['vectorStore'],
    vectorStatus: 'connected',
    version: 'test',
  };
}

function meta(res: Awaited<ReturnType<typeof handleSearch>>) {
  return JSON.parse(res.content[0].text).metadata;
}

describe('handleSearch — vector degraded surfacing', () => {
  it('sets vectorDegraded + a real warning when the vector backend errors', async () => {
    const ctx = makeCtx(async () => {
      throw new Error('lance error: Not found: oracle_knowledge_bge_m3.lance/data/abc.lance');
    });
    const m = meta(await handleSearch(ctx, { query: 'anything' }));
    expect(m.vectorDegraded).toBe(true);
    expect(m.warning).toContain('Vector search unavailable');
    expect(m.warning).toContain('Not found');
  });

  it('does NOT set vectorDegraded when the backend simply returns no results', async () => {
    const ctx = makeCtx(async () => EMPTY_RESULT);
    const m = meta(await handleSearch(ctx, { query: 'anything' }));
    expect(m.vectorDegraded).toBeUndefined();
    // benign no-results warning, not an error warning
    expect(m.warning ?? '').not.toContain('unavailable');
  });

  it('skips the vector path entirely in fts-only mode (no degraded flag)', async () => {
    const ctx = makeCtx(async () => {
      throw new Error('should not be called');
    });
    const m = meta(await handleSearch(ctx, { query: 'anything', mode: 'fts' }));
    expect(m.vectorDegraded).toBeUndefined();
  });
});

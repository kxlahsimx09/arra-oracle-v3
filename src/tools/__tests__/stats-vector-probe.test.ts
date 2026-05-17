/**
 * thread #113 — arra_stats live vector probe.
 *
 * Before this fix, arra_stats reported ctx.vectorStatus, captured once at MCP
 * startup. A drifted LanceDB manifest left it stuck at "connected" while every
 * query fell back to FTS5 — which is why thread #110 sat undetected.
 *
 * handleStats now calls vectorStore.health() (a real probe) and reports
 * vector_status: "degraded" + vector_error when it fails.
 */

import { describe, it, expect } from 'bun:test';
import Database from 'bun:sqlite';
import { drizzle } from 'drizzle-orm/bun-sqlite';
import * as schema from '../../db/schema.ts';
import { handleStats } from '../stats.ts';
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

function makeCtx(vectorStore: unknown, vectorStatus: ToolContext['vectorStatus'] = 'connected'): ToolContext {
  const sqlite = new Database(':memory:');
  sqlite.exec(SCHEMA);
  const db = drizzle(sqlite, { schema });
  return {
    db,
    sqlite,
    repoRoot: '/tmp',
    vectorStore: vectorStore as ToolContext['vectorStore'],
    vectorStatus,
    version: 'test',
  };
}

function parse(res: Awaited<ReturnType<typeof handleStats>>) {
  return JSON.parse(res.content[0].text);
}

describe('handleStats — vector probe', () => {
  it('reports degraded + vector_error when health() returns not-ok (manifest drift)', async () => {
    const ctx = makeCtx({
      health: async () => ({ ok: false, error: 'lance error: Not found: data/abc.lance' }),
    });
    const out = parse(await handleStats(ctx, {}));
    expect(out.vector_status).toBe('degraded');
    expect(out.vector_error).toContain('Not found');
  });

  it('reports connected (no vector_error) when health() passes', async () => {
    const ctx = makeCtx({ health: async () => ({ ok: true, count: 3287 }) });
    const out = parse(await handleStats(ctx, {}));
    expect(out.vector_status).toBe('connected');
    expect(out.vector_error).toBeUndefined();
  });

  it('reports degraded when health() itself throws', async () => {
    const ctx = makeCtx({
      health: async () => { throw new Error('connect refused'); },
    });
    const out = parse(await handleStats(ctx, {}));
    expect(out.vector_status).toBe('degraded');
    expect(out.vector_error).toContain('connect refused');
  });

  it('falls back to startup vectorStatus when the adapter has no health()', async () => {
    const ctx = makeCtx({}, 'unavailable');
    const out = parse(await handleStats(ctx, {}));
    expect(out.vector_status).toBe('unavailable');
    expect(out.vector_error).toBeUndefined();
  });
});

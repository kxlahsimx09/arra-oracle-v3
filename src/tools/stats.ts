/**
 * Oracle Stats Handler
 *
 * Knowledge base statistics and health status.
 */

import { sql, and, ne, isNotNull } from 'drizzle-orm';
import { oracleDocuments } from '../db/schema.ts';
import type { ToolContext, ToolResponse, OracleStatsInput } from './types.ts';

export const statsToolDef = {
  name: 'arra_stats',
  description: 'Get Oracle knowledge base statistics and health status. Returns document counts by type, indexing status, and ChromaDB connection status.',
  inputSchema: {
    type: 'object',
    properties: {},
    required: []
  }
};

export async function handleStats(ctx: ToolContext, _input: OracleStatsInput): Promise<ToolResponse> {
  const typeCounts = ctx.db.select({
    type: oracleDocuments.type,
    count: sql<number>`count(*)`,
  })
    .from(oracleDocuments)
    .groupBy(oracleDocuments.type)
    .all();

  const byType: Record<string, number> = {};
  let totalDocs = 0;
  for (const row of typeCounts) {
    byType[row.type] = row.count;
    totalDocs += row.count;
  }

  const ftsCount = ctx.sqlite.prepare('SELECT COUNT(*) as count FROM oracle_fts').get() as { count: number };

  const lastIndexed = ctx.db.select({
    lastIndexed: sql<number | null>`MAX(indexed_at)`,
  }).from(oracleDocuments).get();

  const conceptsResult = ctx.db.select({
    concepts: oracleDocuments.concepts,
  })
    .from(oracleDocuments)
    .where(and(isNotNull(oracleDocuments.concepts), ne(oracleDocuments.concepts, '[]')))
    .all();

  const uniqueConcepts = new Set<string>();
  for (const row of conceptsResult) {
    try {
      const concepts = JSON.parse(row.concepts);
      if (Array.isArray(concepts)) {
        concepts.forEach((c: string) => uniqueConcepts.add(c));
      }
    } catch {
      // Ignore parse errors
    }
  }

  // Active vector probe. ctx.vectorStatus is captured once at MCP startup and
  // only reflects whether the table handle opened. A drifted LanceDB manifest
  // still answers countRows() but fails search(), so the connect-time status
  // stays "connected" while every query silently falls back to FTS5 — which is
  // why thread #110 sat undetected. health() runs a real query; fall back to
  // the startup status when the adapter does not implement it. See thread #113.
  let vectorStatus: string = ctx.vectorStatus;
  let vectorError: string | undefined;
  if (typeof ctx.vectorStore.health === 'function') {
    try {
      const h = await ctx.vectorStore.health();
      vectorStatus = h.ok ? 'connected' : 'degraded';
      if (!h.ok) vectorError = h.error;
    } catch (e) {
      vectorStatus = 'degraded';
      vectorError = e instanceof Error ? e.message : String(e);
    }
  }

  return {
    content: [{
      type: 'text',
      text: JSON.stringify({
        total_documents: totalDocs,
        by_type: byType,
        fts_indexed: ftsCount.count,
        unique_concepts: uniqueConcepts.size,
        last_indexed: lastIndexed?.lastIndexed
          ? new Date(lastIndexed.lastIndexed).toISOString()
          : null,
        vector_status: vectorStatus,
        ...(vectorError ? { vector_error: vectorError } : {}),
        fts_status: ftsCount.count > 0 ? 'healthy' : 'empty',
        version: ctx.version,
      }, null, 2)
    }]
  };
}

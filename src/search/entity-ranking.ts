import type { Database } from 'bun:sqlite';
import { extractEntities } from '../vector/entities.ts';

const ENTITY_BOOST_PER_MATCH = 0.08;
const ENTITY_BOOST_CAP = 0.24;
const MAX_ENTITY_QUERY_KEYS = 16;
const MAX_RANKING_CANDIDATES = 100;
const QUERY_STOPWORDS = new Set(['a', 'an', 'and', 'are', 'but', 'for', 'from', 'how', 'the', 'this', 'that', 'what', 'when', 'where', 'with', 'why']);

type SqliteLike = Pick<Database, 'prepare'>;
export type EntityLinkRecord = {
  id: string;
  tenantId: string;
  documentId: string;
  entity: string;
  entityKey: string;
  weight: number;
  createdAt: number;
  updatedAt: number;
};
type EntityRankFields = { entity_score?: number; entity_matches?: string[] };
type Rankable = { id: string; score?: number };
type LinkRow = { documentId: string; entity: string; entityKey: string; weight: number };

export function entityKey(value: string): string {
  return value.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '');
}

export function entityLinksForDocument(input: {
  documentId: string;
  tenantId?: string;
  content: string;
  concepts?: unknown;
  now?: number;
}): EntityLinkRecord[] {
  const tenantId = input.tenantId?.trim() || 'default';
  const now = input.now ?? Date.now();
  const links = new Map<string, { entity: string; weight: number }>();
  for (const entity of extractEntities(input.content, input.concepts)) {
    const key = entityKey(entity);
    if (!key) continue;
    const existing = links.get(key);
    links.set(key, { entity: existing?.entity ?? entity, weight: (existing?.weight ?? 0) + 1 });
  }
  return [...links.entries()].map(([key, link]) => ({
    id: `${tenantId}:${input.documentId}:${key}`,
    tenantId,
    documentId: input.documentId,
    entity: link.entity,
    entityKey: key,
    weight: link.weight,
    createdAt: now,
    updatedAt: now,
  }));
}

export function replaceEntityLinks(sqlite: SqliteLike, input: Parameters<typeof entityLinksForDocument>[0]): void {
  const links = entityLinksForDocument(input);
  const tenantId = input.tenantId?.trim() || 'default';
  try {
    sqlite.prepare('DELETE FROM oracle_entity_links WHERE tenant_id = ? AND document_id = ?')
      .run(tenantId, input.documentId);
    const insert = sqlite.prepare(`
      INSERT INTO oracle_entity_links (id, tenant_id, document_id, entity, entity_key, weight, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    for (const link of links) {
      insert.run(link.id, link.tenantId, link.documentId, link.entity, link.entityKey, link.weight, link.createdAt, link.updatedAt);
    }
  } catch (error) {
    if (!isMissingEntityTable(error)) throw error;
  }
}

export function rerankByEntityLinks<T extends Rankable>(
  sqlite: SqliteLike,
  results: T[],
  query: string,
  tenantId?: string,
): Array<T & EntityRankFields> {
  const ids = results.map((result) => result.id).filter(Boolean).slice(0, MAX_RANKING_CANDIDATES);
  const keys = entityKeysForQuery(query);
  if (ids.length === 0 || keys.length === 0) return results;

  const linkMap = new Map<string, Map<string, LinkRow>>();
  try {
    const keyPlaceholders = keys.map(() => '?').join(',');
    const idPlaceholders = ids.map(() => '?').join(',');
    const tenantClause = tenantId ? ' AND tenant_id = ?' : '';
    const rows = sqlite.prepare(`
      SELECT document_id AS documentId, entity, entity_key AS entityKey, weight
      FROM oracle_entity_links
      WHERE entity_key IN (${keyPlaceholders}) AND document_id IN (${idPlaceholders})${tenantClause}
    `).all(...keys, ...ids, ...(tenantId ? [tenantId] : [])) as LinkRow[];
    for (const row of rows) {
      const docLinks = linkMap.get(row.documentId) ?? new Map<string, LinkRow>();
      docLinks.set(row.entityKey, row);
      linkMap.set(row.documentId, docLinks);
    }
  } catch (error) {
    if (isMissingEntityTable(error)) return results;
    throw error;
  }
  if (linkMap.size === 0) return results;

  return results.map((result, index) => {
    const matches = [...(linkMap.get(result.id)?.values() ?? [])];
    const boost = Math.min(ENTITY_BOOST_CAP, matches.length * ENTITY_BOOST_PER_MATCH);
    return {
      ...result,
      score: boost ? Number(((result.score ?? 0) + boost).toFixed(6)) : result.score,
      ...(boost ? { entity_score: Number(boost.toFixed(3)), entity_matches: matches.map((match) => match.entity) } : {}),
      __entityIndex: index,
    };
  }).sort((a, b) => ((b.score ?? 0) - (a.score ?? 0)) || a.__entityIndex - b.__entityIndex)
    .map(({ __entityIndex, ...result }) => result as T & EntityRankFields);
}

function entityKeysForQuery(query: string): string[] {
  const keys = new Set(extractEntities(query).map(entityKey).filter(Boolean));
  const words = query.normalize('NFKC').match(/[\p{L}\p{N}][\p{L}\p{N}._-]{2,}/gu)
    ?.map((word) => word.toLowerCase()).filter((word) => !QUERY_STOPWORDS.has(word)) ?? [];
  for (const word of words) keys.add(entityKey(word));
  for (let i = 0; i < words.length - 1; i += 1) keys.add(entityKey(`${words[i]} ${words[i + 1]}`));
  return [...keys].filter(Boolean).slice(0, MAX_ENTITY_QUERY_KEYS);
}

function isMissingEntityTable(error: unknown): boolean {
  return String(error instanceof Error ? error.message : error).includes('no such table: oracle_entity_links');
}

import { and, desc, eq, inArray, isNull, like, lt, or, sql, type SQL } from 'drizzle-orm';
import type { BunSQLiteDatabase } from 'drizzle-orm/bun-sqlite';
import { db as defaultDb, oracleMemories } from '../../db/index.ts';
import { currentTenantId, tenantIdForWrite } from '../../middleware/tenant.ts';
import type * as schema from '../../db/schema.ts';
import { parseMemoryLimit } from './model.ts';

export type MemoryInput = {
  content: string;
  title?: string;
  tags?: string[];
  source?: string;
  validFrom?: string | number;
  validTo?: string | number | null;
  validUntil?: string | number;
};

export type MemoryRecord = MemoryInput & {
  id: string;
  tenantId?: string;
  createdAt: string;
  updatedAt: string;
  usageCount?: number;
  lastAccessedAt?: string;
  validFrom?: string;
  validTo?: string;
  validUntil?: string;
  supersededBy?: string;
  supersededAt?: string;
  supersededReason?: string;
};

type OracleDb = BunSQLiteDatabase<typeof schema>;
type MemoryRow = typeof oracleMemories.$inferSelect;

export type MemoryDecayOptions = { enabled?: boolean; now?: () => number };

export class MemoryStore {
  constructor(private readonly database?: OracleDb, private readonly decay: MemoryDecayOptions = {}) {}

  private get db(): OracleDb {
    return this.database ?? defaultDb;
  }

  save(input: MemoryInput): MemoryRecord {
    const content = input.content.trim();
    if (!content) throw new Error('memory content is required');
    const now = Date.now();
    const validFrom = parseValidTime(input.validFrom);
    const validTo = parseValidTime(input.validTo ?? input.validUntil);
    if (validFrom && validTo && validTo <= validFrom) throw new Error('valid_to must be after valid_from');
    const row = this.db.insert(oracleMemories).values({
      id: `mem_${now.toString(36)}_${crypto.randomUUID().slice(0, 8)}`,
      tenantId: tenantIdForWrite(),
      content,
      title: input.title?.trim() || null,
      tags: JSON.stringify(cleanTags(input.tags)),
      source: input.source?.trim() || null,
      validFrom: validFrom ?? null,
      validTo: validTo ?? null,
      createdAt: now,
      updatedAt: now,
    }).returning().get();
    return memoryFromRow(row);
  }

  recall(query = '', limit = 10, asOf?: string | number): MemoryRecord[] {
    this.supersedeExpired();
    const normalized = query.trim();
    const safeLimit = parseMemoryLimit(limit);
    const where = combineWhere(tenantWhere(), isNull(oracleMemories.supersededAt), searchWhere(normalized), asOfWhere(parseValidTime(asOf)));
    const selected = this.db.select().from(oracleMemories);
    const rows = where
      ? selected.where(where).orderBy(desc(oracleMemories.createdAt)).limit(safeLimit).all()
      : selected.orderBy(desc(oracleMemories.createdAt)).limit(safeLimit).all();
    return rows.map(memoryFromRow);
  }

  getByIds(ids: string[], asOf?: string | number): MemoryRecord[] {
    if (!ids.length) return [];
    this.supersedeExpired();
    const where = combineWhere(inArray(oracleMemories.id, ids), tenantWhere(), isNull(oracleMemories.supersededAt), asOfWhere(parseValidTime(asOf)));
    const rows = this.db.select().from(oracleMemories).where(where).all();
    const byId = new Map(rows.map((row) => [row.id, memoryFromRow(row)]));
    return ids.map((id) => byId.get(id)).filter((row): row is MemoryRecord => Boolean(row));
  }

  supersedeExpired(reason = 'memory TTL expired'): number {
    if (!this.decay.enabled) return 0;
    const now = this.now();
    const result = this.db.update(oracleMemories)
      .set({ supersededAt: now, supersededReason: reason })
      .where(combineWhere(tenantWhere(), isNull(oracleMemories.supersededAt), lt(oracleMemories.validTo, now)))
      .run() as { changes?: number } | void;
    return result?.changes ?? 0;
  }

  private now(): number {
    return this.decay.now?.() ?? Date.now();
  }

}

function tenantWhere(): SQL | undefined {
  const tenantId = currentTenantId();
  return tenantId ? eq(oracleMemories.tenantId, tenantId) : undefined;
}

function asOfWhere(asOf: number | undefined): SQL | undefined {
  if (!asOf) return undefined;
  return sql`coalesce(${oracleMemories.validFrom}, ${oracleMemories.createdAt}) <= ${asOf}
    and (${oracleMemories.validTo} is null or ${oracleMemories.validTo} > ${asOf})`;
}

function searchWhere(query: string): SQL | undefined {
  if (!query) return undefined;
  return or(
    like(oracleMemories.content, `%${query}%`),
    like(oracleMemories.title, `%${query}%`),
    like(oracleMemories.tags, `%${query}%`),
    like(oracleMemories.source, `%${query}%`),
  );
}

function combineWhere(...clauses: Array<SQL | undefined>): SQL | undefined {
  const present = clauses.filter((clause): clause is SQL => Boolean(clause));
  return present.length > 1 ? and(...present) : present[0];
}

function cleanTags(tags: string[] = []): string[] {
  return tags.map((tag) => tag.trim()).filter(Boolean);
}

export function parseValidTime(value: string | number | null | undefined): number | undefined {
  if (value === null || value === undefined || value === '') return undefined;
  const ms = typeof value === 'number' ? value : Date.parse(value);
  if (!Number.isSafeInteger(ms) || ms <= 0) throw new Error('invalid valid-time timestamp');
  return ms;
}

function tagsFrom(value: string): string[] {
  try {
    const parsed = JSON.parse(value);
    if (Array.isArray(parsed)) return parsed.map(String).filter(Boolean);
  } catch {}
  return [];
}

function memoryFromRow(row: MemoryRow): MemoryRecord {
  return {
    id: row.id,
    tenantId: row.tenantId,
    content: row.content,
    title: row.title ?? undefined,
    tags: tagsFrom(row.tags),
    source: row.source ?? undefined,
    validFrom: row.validFrom ? new Date(row.validFrom).toISOString() : undefined,
    validTo: row.validTo ? new Date(row.validTo).toISOString() : undefined,
    validUntil: row.validTo ? new Date(row.validTo).toISOString() : undefined,
    supersededBy: row.supersededBy ?? undefined,
    supersededAt: row.supersededAt ? new Date(row.supersededAt).toISOString() : undefined,
    supersededReason: row.supersededReason ?? undefined,
    createdAt: new Date(row.createdAt).toISOString(),
    updatedAt: new Date(row.updatedAt).toISOString(),
  };
}

export const memoryStore = new MemoryStore(undefined, {
  enabled: process.env.MEMORY_TTL_AUTOSUPERSEDE === '1'
    || process.env.MEMORY_TTL_AUTOSUPERSEDE === 'true',
});

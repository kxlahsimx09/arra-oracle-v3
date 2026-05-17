/**
 * LanceDB Adapter
 *
 * Serverless columnar vector DB. Stores data as Lance files on disk.
 * Uses EmbeddingProvider since LanceDB doesn't generate embeddings.
 */

import type { VectorStoreAdapter, VectorDocument, VectorQueryResult, EmbeddingProvider } from '../types.ts';

export class LanceDBAdapter implements VectorStoreAdapter {
  readonly name = 'lancedb';
  private db: any = null;
  private table: any = null;
  private dbPath: string;
  private collectionName: string;
  private embedder: EmbeddingProvider;

  /**
   * Serializes writes within this process. Two concurrent addDocuments()
   * calls that interleave their `table.add()` can produce a LanceDB manifest
   * version referencing a fragment the other writer has not flushed yet —
   * the manifest-drift failure (thread #113, recurrences 2026-04-14/04-21/05-16).
   * NOTE: this guards in-process concurrency only. `@lancedb/lancedb@0.27.2`
   * has no inter-process write lock, so concurrent writes from other Oracle
   * processes (other MCP server instances, the HTTP server) can still drift a
   * manifest. The inter-process file lock is tracked as thread #113 Phase 2.
   */
  private writeChain: Promise<void> = Promise.resolve();

  constructor(collectionName: string, dbPath: string, embedder: EmbeddingProvider) {
    this.collectionName = collectionName;
    this.dbPath = dbPath;
    this.embedder = embedder;
  }

  async connect(): Promise<void> {
    if (this.db) return;

    const lancedb = await import('@lancedb/lancedb');
    this.db = await lancedb.connect(this.dbPath);
    console.log(`[LanceDB] Connected at ${this.dbPath}`);
  }

  async close(): Promise<void> {
    this.db = null;
    this.table = null;
    console.log('[LanceDB] Closed');
  }

  /**
   * Detect LanceDB stale-snapshot errors.
   *
   * When a reindex (compaction + GC) runs while this process holds an open
   * connection, the cached snapshot points at fragment files that no longer
   * exist on disk. Subsequent reads surface as `lance error: Not found: ...
   * .lance`. Re-opening the connection reads the latest manifest and resolves it.
   */
  private isStaleSnapshotError(err: unknown): boolean {
    const msg = err instanceof Error ? err.message : String(err);
    return /lance error:\s*Not found.*\.lance/i.test(msg);
  }

  private async reopenConnection(): Promise<void> {
    this.db = null;
    this.table = null;
    await this.connect();
    await this.ensureCollection();
  }

  private async withStaleRetry<T>(op: string, fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } catch (err) {
      if (!this.isStaleSnapshotError(err)) throw err;
      console.warn(`[LanceDB] Stale snapshot in ${op} — reopening connection and retrying once`);
      await this.reopenConnection();
      return await fn();
    }
  }

  async ensureCollection(): Promise<void> {
    if (!this.db) throw new Error('LanceDB not connected');

    const tableNames = await this.db.tableNames();
    if (tableNames.includes(this.collectionName)) {
      this.table = await this.db.openTable(this.collectionName);
    } else {
      // Create with a schema-defining dummy row, then delete it
      const dims = this.embedder.dimensions;
      this.table = await this.db.createTable(this.collectionName, [{
        id: '__init__',
        text: '',
        metadata: '{}',
        vector: new Array(dims).fill(0),
      }]);
      await this.table.delete('id = "__init__"');
    }

    console.log(`[LanceDB] Collection '${this.collectionName}' ready`);
  }

  async deleteCollection(): Promise<void> {
    if (!this.db) throw new Error('LanceDB not connected');

    try {
      await this.db.dropTable(this.collectionName);
      this.table = null;
      console.log(`[LanceDB] Collection '${this.collectionName}' deleted`);
    } catch (e) {
      console.warn('[LanceDB] deleteCollection failed:', e instanceof Error ? e.message : String(e));
    }
  }

  async addDocuments(docs: VectorDocument[]): Promise<void> {
    if (docs.length === 0) return;
    // Chain onto the prior write so concurrent callers in this process
    // serialize. The chain keeps advancing even if a write rejects, so one
    // failed write does not wedge every subsequent one.
    const run = this.writeChain.then(() => this.addDocumentsLocked(docs));
    this.writeChain = run.then(() => {}, () => {});
    return run;
  }

  private async addDocumentsLocked(docs: VectorDocument[]): Promise<void> {
    if (!this.table) await this.ensureCollection();

    const texts = docs.map(d => d.document);
    const embeddings = await this.embedder.embed(texts);

    const rows = docs.map((doc, i) => ({
      id: doc.id,
      text: doc.document,
      metadata: JSON.stringify(doc.metadata),
      vector: embeddings[i],
    }));

    await this.table.add(rows);
    console.log(`[LanceDB] Added ${docs.length} documents`);
  }

  async query(text: string, limit: number = 10, where?: Record<string, any>): Promise<VectorQueryResult> {
    if (!this.table) await this.ensureCollection();

    const [queryEmbedding] = await this.embedder.embed([text]);

    // Fetch extra results if filtering in JS (metadata is stored as string, not binary)
    const fetchLimit = where ? limit * 3 : limit;
    const results = await this.withStaleRetry<any[]>('query', () =>
      this.table.search(queryEmbedding).limit(fetchLimit).toArray()
    );

    // Filter metadata in JavaScript (LanceDB json_extract requires LargeBinary, not Utf8)
    let filtered = results;
    if (where) {
      filtered = results.filter((r: any) => {
        const meta = JSON.parse(r.metadata || '{}');
        return Object.entries(where).every(([k, v]) => meta[k] === v);
      }).slice(0, limit);
    }

    return {
      ids: filtered.map((r: any) => r.id),
      documents: filtered.map((r: any) => r.text),
      distances: filtered.map((r: any) => r._distance ?? 0),
      metadatas: filtered.map((r: any) => JSON.parse(r.metadata || '{}')),
    };
  }

  async queryById(id: string, nResults: number = 5): Promise<VectorQueryResult> {
    if (!this.table) await this.ensureCollection();

    // Get the document's vector using filter query (not vector search)
    const rows = await this.withStaleRetry<any[]>('queryById:lookup', () =>
      this.table.query().where(`id = '${id}'`).limit(1).toArray()
    );
    if (rows.length === 0) {
      throw new Error(`No embedding found for document: ${id}`);
    }

    const vector = Array.from(rows[0].vector);
    const results = await this.withStaleRetry<any[]>('queryById:search', () =>
      this.table.search(vector).limit(nResults + 1).toArray()
    );

    const filtered = results.filter((r: any) => r.id !== id).slice(0, nResults);

    return {
      ids: filtered.map((r: any) => r.id),
      documents: filtered.map((r: any) => r.text),
      distances: filtered.map((r: any) => r._distance ?? 0),
      metadatas: filtered.map((r: any) => JSON.parse(r.metadata || '{}')),
    };
  }

  async getStats(): Promise<{ count: number }> {
    if (!this.table) {
      // Try to open existing table
      if (this.db) {
        try {
          const tableNames = await this.db.tableNames();
          if (tableNames.includes(this.collectionName)) {
            this.table = await this.db.openTable(this.collectionName);
          }
        } catch {}
      }
      if (!this.table) return { count: 0 };
    }
    try {
      const count = await this.withStaleRetry<number>('getStats', () => this.table.countRows());
      return { count };
    } catch {
      return { count: 0 };
    }
  }

  async getCollectionInfo(): Promise<{ count: number; name: string }> {
    const stats = await this.getStats();
    return { count: stats.count, name: this.collectionName };
  }

  /**
   * Active health probe. Runs a real vector search so a drifted manifest is
   * detected: countRows() answers from manifest metadata even when a data
   * fragment is missing, but search() must read fragments and throws
   * `lance error: Not found …` on drift. A zero query vector is used so the
   * probe needs no Ollama round-trip; it still exercises the fragment-read
   * path. See thread #113 — this is the signal arra_stats must report instead
   * of the connect-time-only vectorStatus.
   */
  async health(): Promise<{ ok: boolean; error?: string; count?: number }> {
    try {
      if (!this.table) await this.ensureCollection();
      const probe = new Array(this.embedder.dimensions).fill(0);
      await this.table.search(probe).distanceType('cosine').limit(1).toArray();
      const count = await this.table.countRows();
      return { ok: true, count };
    } catch (e) {
      return { ok: false, error: e instanceof Error ? e.message : String(e) };
    }
  }

  async getAllEmbeddings(limit: number = 5000): Promise<{ ids: string[]; embeddings: number[][]; metadatas: any[] }> {
    if (!this.table) return { ids: [], embeddings: [], metadatas: [] };

    const rows = await this.withStaleRetry<any[]>('getAllEmbeddings', () =>
      this.table.query().limit(limit).toArray()
    );

    return {
      ids: rows.map((r: any) => r.id),
      embeddings: rows.map((r: any) => Array.from(r.vector)),
      metadatas: rows.map((r: any) => JSON.parse(r.metadata || '{}')),
    };
  }
}

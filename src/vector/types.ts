/**
 * Vector Store Adapter Types
 *
 * Pluggable interface for vector databases.
 * Derived from ChromaMcpClient's public API.
 */

export interface VectorDocument {
  id: string;
  document: string;
  metadata: Record<string, string | number>;
}

export interface VectorQueryResult {
  ids: string[];
  documents: string[];
  distances: number[];
  metadatas: any[];
}

/**
 * Pluggable vector store interface.
 * Any vector DB (ChromaDB, sqlite-vec, Qdrant, LanceDB) implements this.
 */
export interface VectorStoreAdapter {
  readonly name: string;
  connect(): Promise<void>;
  close(): Promise<void>;
  ensureCollection(): Promise<void>;
  deleteCollection(): Promise<void>;
  addDocuments(docs: VectorDocument[]): Promise<void>;
  query(text: string, limit?: number, where?: Record<string, any>): Promise<VectorQueryResult>;
  queryById(id: string, nResults?: number): Promise<VectorQueryResult>;
  getStats(): Promise<{ count: number }>;
  getCollectionInfo(): Promise<{ count: number; name: string }>;
  getAllEmbeddings?(limit?: number): Promise<{ ids: string[]; embeddings: number[][]; metadatas: any[] }>;
  /**
   * Active health probe — runs a real query so backend faults that getStats()
   * cannot see are detected. LanceDB manifest drift is the motivating case:
   * countRows() still answers from manifest metadata while search() fails on a
   * missing data fragment. Optional — callers fall back to getStats() when an
   * adapter does not implement it. See thread #113.
   */
  health?(): Promise<{ ok: boolean; error?: string; count?: number }>;
}

/**
 * Embedding provider interface.
 * Separated from storage because ChromaDB handles embeddings internally,
 * while sqlite-vec/Qdrant/LanceDB need external embeddings.
 */
export interface EmbeddingProvider {
  readonly name: string;
  readonly dimensions: number;
  embed(texts: string[]): Promise<number[][]>;
}

export type VectorDBType = 'chroma' | 'sqlite-vec' | 'lancedb' | 'qdrant' | 'cloudflare-vectorize';
export type EmbeddingProviderType = 'chromadb-internal' | 'ollama' | 'openai' | 'cloudflare-ai';

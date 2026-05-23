/**
 * Boot integrity check (thread #115 Phase 3).
 *
 * At process startup, probe the active embedding model's LanceDB collection
 * with the adapter's `health()` — a real vector search that reads fragments,
 * so a drifted manifest (the thread #115 failure mode: `countRows()` still
 * answers from manifest metadata but `search()` throws `lance error: Not
 * found …`) is caught at BOOT, not weeks later at an audit.
 *
 * On drift we emit a LOUD, actionable signal that NAMES the rebuild command.
 * We deliberately do NOT auto-rebuild (P-003 — External Brain, not Commander):
 * a rebuild is ~7 min, would block startup, and races live writers (the
 * manifest-drift hazard itself). The operator runs the named command when
 * ready. Phase 2's inter-process write lock is what prevents NEW drift; this
 * check surfaces any PRE-EXISTING drift loudly at the next boot.
 *
 * Never throws and never mutates the store — a boot check must not be able to
 * wedge or alter the process it guards.
 */
import { getEmbeddingModels, ensureVectorStoreConnected } from './factory.ts';

export interface ModelIntegrity {
  model: string;
  collection: string;
  ok: boolean;
  count?: number;
  error?: string;
}

export interface BootIntegrityResult {
  ok: boolean;
  models: ModelIntegrity[];
}

/** The canonical rebuild-from-SQLite command (see src/scripts/index-model.ts). */
export const rebuildCommand = (model: string): string => `bun src/scripts/index-model.ts ${model}`;

interface HealthyStore {
  health?: () => Promise<{ ok: boolean; error?: string; count?: number }>;
}

export interface BootIntegrityOptions {
  /** Models to probe. Defaults to the active model (ORACLE_EMBEDDING_MODEL || bge-m3). */
  models?: string[];
  /** Log sink. Defaults to console.error (stderr — safe for the MCP stdio server). */
  log?: (msg: string) => void;
  /** Store connector. Injectable for tests; defaults to the real registry. */
  connect?: (model: string) => Promise<HealthyStore>;
}

/**
 * Probe each model's vector store and report integrity. Logs a loud,
 * rebuild-command-naming signal on drift. Returns the per-model results.
 */
export async function runBootIntegrityCheck(opts: BootIntegrityOptions = {}): Promise<BootIntegrityResult> {
  const registry = getEmbeddingModels();
  const log = opts.log ?? ((m: string) => console.error(m));
  const connect = opts.connect ?? ensureVectorStoreConnected;
  const models = opts.models ?? [process.env.ORACLE_EMBEDDING_MODEL || 'bge-m3'];

  const results: ModelIntegrity[] = [];
  for (const model of models) {
    const collection = registry[model]?.collection ?? model;
    try {
      const store = await connect(model);
      if (typeof store.health !== 'function') {
        // Adapter without an active probe (non-LanceDB) — nothing to verify.
        results.push({ model, collection, ok: true });
        continue;
      }
      const h = await store.health();
      results.push({ model, collection, ok: h.ok, count: h.count, error: h.error });
    } catch (e) {
      results.push({ model, collection, ok: false, error: e instanceof Error ? e.message : String(e) });
    }
  }

  const degraded = results.filter((r) => !r.ok);
  if (degraded.length === 0) {
    log(`✅ [boot-integrity] vector store OK — ${results.length} model(s) probed, no manifest drift.`);
    return { ok: true, models: results };
  }

  log('');
  log('🛑 ════════════════════════════════════════════════════════════');
  log('🛑  VECTOR STORE INTEGRITY CHECK FAILED — LanceDB manifest drift');
  log('🛑 ════════════════════════════════════════════════════════════');
  for (const d of degraded) {
    log(`🛑  collection "${d.collection}" (model ${d.model}) is DEGRADED`);
    log(`🛑    error: ${d.error ?? 'unknown'}`);
    log('🛑    → hybrid search for this model is silently FTS5-only until rebuilt.');
    log(`🛑    → REBUILD (operator-invoked, ~7min, NOT automatic): ${rebuildCommand(d.model)}`);
  }
  log('🛑  Phase 2 inter-process lock prevents NEW drift; the above is pre-existing.');
  log('🛑  No auto-rebuild (P-003): a rebuild races live writers — run it deliberately.');
  log('🛑 ════════════════════════════════════════════════════════════');
  log('');

  return { ok: false, models: results };
}

/**
 * thread #115 Phase 3 — boot integrity check.
 *
 * The check probes each model's vector store with health() and, on drift,
 * emits a loud signal that NAMES the rebuild command. It must never throw and
 * never auto-rebuild (P-003). The store connector is injected so these tests
 * never touch a real LanceDB.
 */
import { describe, it, expect } from 'bun:test';
import { runBootIntegrityCheck, rebuildCommand } from '../boot-integrity.ts';

const healthy = () => ({ health: async () => ({ ok: true, count: 42 }) });
const drifted = (error: string) => () => ({ health: async () => ({ ok: false, error }) });

describe('runBootIntegrityCheck', () => {
  it('reports ok and logs a clean line when health() passes', async () => {
    const logs: string[] = [];
    const res = await runBootIntegrityCheck({
      models: ['bge-m3'],
      log: (m) => logs.push(m),
      connect: async () => healthy(),
    });

    expect(res.ok).toBe(true);
    expect(res.models[0]).toMatchObject({ model: 'bge-m3', ok: true, count: 42 });
    expect(logs.join('\n')).toContain('vector store OK');
    expect(logs.join('\n')).not.toContain('🛑');
  });

  it('on drift, logs a loud signal NAMING the rebuild command', async () => {
    const logs: string[] = [];
    const res = await runBootIntegrityCheck({
      models: ['bge-m3'],
      log: (m) => logs.push(m),
      connect: drifted('lance error: Not found: oracle_knowledge_bge_m3.lance/data/x.lance'),
    });

    const out = logs.join('\n');
    expect(res.ok).toBe(false);
    expect(out).toContain('INTEGRITY CHECK FAILED');
    expect(out).toContain('bun src/scripts/index-model.ts bge-m3'); // exact rebuild cmd
    expect(out).toContain('Not found');
    expect(out).toContain('No auto-rebuild'); // P-003 stated in the signal
  });

  it('never throws when the connector itself fails — reports degraded', async () => {
    const res = await runBootIntegrityCheck({
      models: ['bge-m3'],
      log: () => {},
      connect: async () => { throw new Error('ollama down / connect failed'); },
    });

    expect(res.ok).toBe(false);
    expect(res.models[0].ok).toBe(false);
    expect(res.models[0].error).toContain('connect failed');
  });

  it('treats an adapter without health() as not-checkable (ok)', async () => {
    const res = await runBootIntegrityCheck({
      models: ['bge-m3'],
      log: () => {},
      connect: async () => ({}), // no health()
    });
    expect(res.ok).toBe(true);
  });

  it('aggregates multiple models and fails if any is drifted', async () => {
    const res = await runBootIntegrityCheck({
      models: ['bge-m3', 'qwen3'],
      log: () => {},
      connect: async (model) => (model === 'qwen3' ? drifted('boom')() : healthy()),
    });

    expect(res.ok).toBe(false);
    expect(res.models).toHaveLength(2);
    expect(res.models.find((m) => m.model === 'bge-m3')!.ok).toBe(true);
    expect(res.models.find((m) => m.model === 'qwen3')!.ok).toBe(false);
  });

  it('rebuildCommand names the per-model SQLite-rebuild script', () => {
    expect(rebuildCommand('qwen3')).toBe('bun src/scripts/index-model.ts qwen3');
  });
});

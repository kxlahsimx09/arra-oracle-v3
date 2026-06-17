import { afterEach, describe, expect, test } from 'bun:test';
import { eq } from 'drizzle-orm';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { parseMineArgs } from '../../../src/cli/commands/mine.ts';
import { createDatabase } from '../../../src/db/index.ts';
import { oracleDocuments } from '../../../src/db/schema.ts';
import { mineFolder, stableMineDocId, watchMineFolder } from '../../../src/indexer/mine.ts';

let tempDir = '';

afterEach(() => {
  if (tempDir && fs.existsSync(tempDir)) fs.rmSync(tempDir, { recursive: true });
  tempDir = '';
});

function tmp(): string {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'arra-mine-'));
  return tempDir;
}

describe('arra mine folder ingest', () => {
  test('parses friendly command flags and rejects bad input', () => {
    expect(parseMineArgs(['notes', '--db-path', '/tmp/oracle.db'])).toEqual({
      dir: 'notes', dbPath: '/tmp/oracle.db', dryRun: false, watch: false, help: false,
    });
    expect(parseMineArgs(['--dry-run', '--watch', '--db-path=/tmp/oracle.db', 'notes']).dryRun).toBe(true);
    expect(parseMineArgs(['-w', 'notes']).watch).toBe(true);
    expect(() => parseMineArgs(['notes', '--bad'])).toThrow('unknown mine option: --bad');
    expect(() => parseMineArgs(['--db-path'])).toThrow('--db-path requires a path');
  });

  test('stores deterministic docs and skips unchanged reruns', async () => {
    const root = tmp();
    const dbPath = path.join(root, 'oracle.db');
    const notes = path.join(root, 'notes');
    fs.mkdirSync(path.join(notes, 'ops'), { recursive: true });
    const notePath = path.join(notes, 'ops', 'deploy.md');
    fs.writeFileSync(notePath, '# Deploy\n\nRollback checklist and deployment notes.');

    const first = await mineFolder({ dir: notes, dbPath });
    const second = await mineFolder({ dir: notes, dbPath });

    expect(first).toMatchObject({ scanned: 1, stored: 1, skipped: 0, project: 'notes' });
    expect(second).toMatchObject({ scanned: 1, stored: 0, skipped: 1, project: 'notes' });

    const id = stableMineDocId(notes, notePath);
    const { db, storage } = createDatabase(dbPath);
    const row = db.select().from(oracleDocuments).where(eq(oracleDocuments.id, id)).get();
    storage.close();

    expect(row?.sourceFile).toBe('mine/notes/ops/deploy.md');
    expect(row?.createdBy).toBe('mine');
    expect(JSON.parse(row?.concepts ?? '[]')).toContain('ops');
  });

  test('stores long notes as deterministic paragraph chunks', async () => {
    const root = tmp();
    const dbPath = path.join(root, 'oracle.db');
    const notes = path.join(root, 'notes');
    fs.mkdirSync(path.join(notes, 'ops'), { recursive: true });
    const notePath = path.join(notes, 'ops', 'long.md');
    const para = (label: string, char: string) => `${label} ${char.repeat(330)}`;
    fs.writeFileSync(notePath, [para('alpha', 'a'), '', para('beta', 'b'), '', para('gamma', 'c')].join('\n'));

    const first = await mineFolder({ dir: notes, dbPath });
    const second = await mineFolder({ dir: notes, dbPath });

    expect(first).toMatchObject({ scanned: 1, stored: 2, skipped: 0 });
    expect(second).toMatchObject({ scanned: 1, stored: 0, skipped: 1 });

    const id = stableMineDocId(notes, notePath);
    const { db, storage } = createDatabase(dbPath);
    const rows = db.select().from(oracleDocuments).orderBy(oracleDocuments.id).all();
    storage.close();

    expect(rows.map((row) => row.id)).toEqual([`${id}__chunk_0`, `${id}__chunk_1`]);
    expect(rows.every((row) => row.createdBy === 'mine')).toBe(true);
  });

  test('watch re-ingests changed files after the initial run', async () => {
    const root = tmp();
    const dbPath = path.join(root, 'oracle.db');
    const notes = path.join(root, 'notes');
    fs.mkdirSync(notes, { recursive: true });
    const notePath = path.join(notes, 'watch.md');
    fs.writeFileSync(notePath, 'first version');

    const controller = new AbortController();
    const results: number[] = [];
    const watchDone = watchMineFolder(
      { dir: notes, dbPath, debounceMs: 20, signal: controller.signal },
      (result) => {
        results.push(result.stored);
        if (results.length === 1) fs.writeFileSync(notePath, 'second version');
        if (results.length >= 2) controller.abort();
      },
    );

    await watchDone;

    expect(results).toEqual([1, 1]);
  });
});

import fs from 'fs';
import path from 'path';
import { createHash } from 'crypto';
import { eq } from 'drizzle-orm';
import { createDatabase } from '../db/index.ts';
import { oracleDocuments } from '../db/schema.ts';
import { detectProject } from '../server/project-detect.ts';
import type { OracleDocument } from '../types.ts';
import { extractConcepts, mergeConceptsWithTags } from './concepts.ts';
import { chunkDocumentForIndexing } from './chunk-text.ts';
import { storeDocuments } from './storage.ts';

const DEFAULT_EXTENSIONS = new Set(['.md', '.mdx', '.txt']);
const SKIP_DIRS = new Set(['.git', 'node_modules', 'dist', 'build', '.next', '.turbo']);

export interface MineOptions { dir: string; dbPath?: string; dryRun?: boolean }
export interface MineResult { scanned: number; stored: number; skipped: number; project: string; root: string }
export interface MineWatchOptions extends MineOptions { signal?: AbortSignal; debounceMs?: number }

export function stableMineDocId(root: string, filePath: string): string {
  const rel = relativeSource(root, filePath);
  return `mine_${createHash('sha256').update(rel).digest('hex').slice(0, 24)}`;
}

export function contentVersion(content: string): number {
  return parseInt(createHash('sha256').update(content).digest('hex').slice(0, 12), 16);
}

export function collectMineFiles(root: string): string[] {
  const files: string[] = [];
  function walk(dir: string): void {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.startsWith('.') && entry.name !== '.notes') continue;
      if (SKIP_DIRS.has(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && DEFAULT_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) files.push(full);
    }
  }
  walk(root);
  return files.sort();
}

export async function mineFolder(options: MineOptions): Promise<MineResult> {
  const root = path.resolve(options.dir);
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    throw new Error(`mine target must be a directory: ${options.dir}`);
  }
  const files = collectMineFiles(root);
  const project = detectProject(root) || path.basename(root).toLowerCase();
  const { sqlite, db, storage } = createDatabase(options.dbPath);
  try {
    const docs: OracleDocument[] = [];
    let skipped = 0;
    for (const file of files) {
      const content = fs.readFileSync(file, 'utf8').trim();
      if (!content) { skipped++; continue; }
      const id = stableMineDocId(root, file);
      const updatedAt = contentVersion(content);
      const nextDocs = chunkDocumentForIndexing(toMineDocument(root, file, content, id, updatedAt, project));
      const unchanged = nextDocs.every((doc) => {
        const existing = db.select({ updatedAt: oracleDocuments.updatedAt })
          .from(oracleDocuments).where(eq(oracleDocuments.id, doc.id)).get();
        return existing?.updatedAt === updatedAt;
      });
      if (unchanged) { skipped++; continue; }
      docs.push(...nextDocs);
    }
    if (!options.dryRun && docs.length > 0) {
      await storeDocuments(sqlite, db, null, project, docs, { createdBy: 'mine' });
    }
    return { scanned: files.length, stored: options.dryRun ? docs.length : docs.length, skipped, project, root };
  } finally {
    storage.close();
  }
}

export async function watchMineFolder(
  options: MineWatchOptions,
  onResult: (result: MineResult) => void = () => {},
): Promise<void> {
  const root = path.resolve(options.dir);
  const signal = options.signal;
  const debounceMs = options.debounceMs ?? 300;
  const watchers: fs.FSWatcher[] = [];
  let timer: ReturnType<typeof setTimeout> | undefined;
  let running = Promise.resolve();

  const run = () => {
    running = running.then(async () => onResult(await mineFolder(options)));
    return running;
  };
  const schedule = () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => { void run(); }, debounceMs);
  };
  const close = () => {
    if (timer) clearTimeout(timer);
    for (const watcher of watchers) watcher.close();
  };

  for (const dir of collectMineDirs(root)) watchers.push(fs.watch(dir, schedule));
  await run();
  if (signal?.aborted) return close();
  await new Promise<void>((resolve) => {
    signal?.addEventListener('abort', () => { close(); resolve(); }, { once: true });
  });
  await running;
}

function collectMineDirs(root: string): string[] {
  const dirs = [root];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory() || SKIP_DIRS.has(entry.name) || entry.name.startsWith('.')) continue;
    dirs.push(...collectMineDirs(path.join(root, entry.name)));
  }
  return dirs;
}

function toMineDocument(root: string, file: string, content: string, id: string, version: number, project: string): OracleDocument {
  const source = relativeSource(root, file);
  const title = path.basename(file, path.extname(file));
  const folders = path.dirname(source).split('/').filter(part => part && part !== '.');
  const concepts = mergeConceptsWithTags(extractConcepts(title, content), [project, ...folders]);
  return {
    id, type: 'learning', source_file: source, content,
    concepts, created_at: fs.statSync(file).birthtimeMs || version,
    updated_at: version, project,
  };
}

function relativeSource(root: string, filePath: string): string {
  return `mine/${path.basename(root)}/${path.relative(root, filePath).split(path.sep).join('/')}`;
}

/**
 * GET /api/inbox — list envelopes from ψ/inbox/.
 *
 * Two envelope flavors live side by side under ψ/inbox/:
 *   - handoff/        — self-to-self context pass (oracle_handoff)
 *   - for-{oracle}/   — directed cross-agent envelopes (AGENTS.md §11)
 *
 * Query params:
 *   type=all|handoff|directed   (default: all)
 *   oracle=<name>               filter directed to for-{oracle}/ only
 *   include_archived=1          also walk handled/YYYY-MM/ subdirs
 *   limit, offset               pagination (default 10, 0)
 *
 * Directed envelopes are returned with parsed frontmatter so the UI
 * can render from/to/thread badges without re-fetching the file body.
 */

import { Elysia } from 'elysia';
import fs from 'fs';
import path from 'path';
import { REPO_ROOT } from '../../config.ts';
import { InboxQuery } from './model.ts';

interface EnvelopeMeta {
  filename: string;
  path: string;
  created: string;
  preview: string;
  type: 'handoff' | 'directed';
  archived: boolean;
  // directed-only (parsed from yaml frontmatter)
  oracle?: string;
  from?: string;
  to?: string;
  from_role?: string;
  to_role?: string;
  thread?: number;
  envelope_type?: string; // consult | escalate | notify
  subject?: string;
  priority?: string;
  handled_at?: string;
  handled_by_thread?: number;
}

function extractCreated(filename: string): string {
  const m = filename.match(/^(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2})/);
  return m ? `${m[1]}T${m[2].replace('-', ':')}:00` : 'unknown';
}

/**
 * Parse the leading YAML frontmatter block (between `---` fences).
 * Returns a flat map of string fields. Ignores nested structures —
 * envelopes use a flat schema by convention (§11b).
 */
function parseFrontmatter(content: string): Record<string, string> {
  const out: Record<string, string> = {};
  const lines = content.split('\n');
  if (lines[0]?.trim() !== '---') return out;

  let i = 1;
  let currentKey: string | null = null;
  let folded: string[] = [];

  for (; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === '---') break;

    // YAML folded scalar (`key: >`) — accumulate continuation lines.
    if (currentKey && line.startsWith('  ')) {
      folded.push(line.trim());
      continue;
    }
    if (currentKey) {
      out[currentKey] = folded.join(' ');
      currentKey = null;
      folded = [];
    }

    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):\s*(.*)$/);
    if (!m) continue;
    const [, key, rawVal] = m;
    const val = rawVal.trim();

    if (val === '>' || val === '|') {
      currentKey = key;
      continue;
    }

    out[key] = val.replace(/^["']|["']$/g, '').replace(/\s+#.*$/, '').trim();
  }

  if (currentKey) out[currentKey] = folded.join(' ');
  return out;
}

function listMdFiles(dir: string, recurse = false): string[] {
  if (!fs.existsSync(dir)) return [];
  const found: string[] = [];
  const stack: string[] = [dir];
  while (stack.length) {
    const cur = stack.pop()!;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(cur, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      const full = path.join(cur, e.name);
      if (e.isDirectory()) {
        if (recurse && e.name !== 'handled') stack.push(full);
        else if (recurse && e.name === 'handled') stack.push(full);
      } else if (e.isFile() && e.name.endsWith('.md') && e.name !== '.gitkeep') {
        found.push(full);
      }
    }
  }
  return found;
}

function readEnvelope(filePath: string, inboxRoot: string, type: 'handoff' | 'directed', archived: boolean): EnvelopeMeta {
  const filename = path.basename(filePath);
  const relPath = path.relative(REPO_ROOT, filePath).replace(/\\/g, '/');
  const content = fs.readFileSync(filePath, 'utf-8');
  const meta: EnvelopeMeta = {
    filename,
    path: relPath,
    created: extractCreated(filename),
    preview: content.substring(0, 500),
    type,
    archived,
  };

  if (type === 'directed') {
    const fm = parseFrontmatter(content);
    if (fm.from) meta.from = fm.from;
    if (fm.to) meta.to = fm.to;
    if (fm.from_role) meta.from_role = fm.from_role;
    if (fm.to_role) meta.to_role = fm.to_role;
    if (fm.thread) meta.thread = parseInt(fm.thread);
    if (fm.type) meta.envelope_type = fm.type;
    if (fm.subject) meta.subject = fm.subject;
    if (fm.priority) meta.priority = fm.priority;
    if (fm.handled_at) meta.handled_at = fm.handled_at;
    if (fm.handled_by_thread) meta.handled_by_thread = parseInt(fm.handled_by_thread);
    // oracle from path: ψ/inbox/for-{oracle}/(handled/...)?
    const oracleMatch = relPath.match(/inbox\/for-([^/]+)\//);
    if (oracleMatch) meta.oracle = oracleMatch[1];
  }

  return meta;
}

export const inboxEndpoint = new Elysia().get(
  '/inbox',
  ({ query }) => {
    const limit = parseInt(query.limit ?? '10');
    const offset = parseInt(query.offset ?? '0');
    const type = query.type ?? 'all';
    const oracleFilter = query.oracle;
    const includeArchived = query.include_archived === '1';

    const inboxDir = path.join(REPO_ROOT, 'ψ/inbox');
    const results: EnvelopeMeta[] = [];

    // Handoff files (existing behavior)
    if (type === 'all' || type === 'handoff') {
      const handoffDir = path.join(inboxDir, 'handoff');
      const files = listMdFiles(handoffDir, false);
      for (const f of files) {
        results.push(readEnvelope(f, inboxDir, 'handoff', false));
      }
    }

    // Directed envelopes — for-{oracle}/ subdirs
    if (type === 'all' || type === 'directed') {
      let oracleDirs: string[];
      if (oracleFilter) {
        const dir = path.join(inboxDir, `for-${oracleFilter}`);
        oracleDirs = fs.existsSync(dir) ? [dir] : [];
      } else if (fs.existsSync(inboxDir)) {
        oracleDirs = fs
          .readdirSync(inboxDir, { withFileTypes: true })
          .filter(e => e.isDirectory() && e.name.startsWith('for-'))
          .map(e => path.join(inboxDir, e.name));
      } else {
        oracleDirs = [];
      }

      for (const dir of oracleDirs) {
        // Active envelopes (root of for-{oracle}/)
        for (const f of listMdFiles(dir, false)) {
          results.push(readEnvelope(f, inboxDir, 'directed', false));
        }
        // Archived (handled/YYYY-MM/*.md) only when requested
        if (includeArchived) {
          const handledDir = path.join(dir, 'handled');
          for (const f of listMdFiles(handledDir, true)) {
            results.push(readEnvelope(f, inboxDir, 'directed', true));
          }
        }
      }
    }

    // Newest first by filename (ISO date prefix sorts naturally)
    results.sort((a, b) => b.filename.localeCompare(a.filename));

    const total = results.length;
    const paginated = results.slice(offset, offset + limit);

    return { files: paginated, total, limit, offset };
  },
  {
    query: InboxQuery,
    detail: {
      tags: ['knowledge'],
      menu: { group: 'hidden' },
      summary: 'List inbox envelopes (handoff + directed for-{oracle}/)',
    },
  },
);

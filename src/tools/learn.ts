/**
 * Oracle Learn Handler
 *
 * Add new patterns/learnings to the knowledge base.
 * Exports normalizeProject and extractProjectFromSource for testability.
 */

import path from 'path';
import fs from 'fs';
import { oracleDocuments } from '../db/schema.ts';
import { detectProject } from '../server/project-detect.ts';
import { getVaultPsiRoot } from '../vault/handler.ts';
import { ensureVectorStoreConnected } from '../vector/factory.ts';
import { REPO_ROOT } from '../config.ts';
import type { ToolContext, ToolResponse, OracleLearnInput } from './types.ts';

/** Coerce concepts to string[] — handles string, array, or undefined from MCP input */
export function coerceConcepts(concepts: unknown): string[] {
  if (Array.isArray(concepts)) return concepts.map(String);
  if (typeof concepts === 'string') return concepts.split(',').map(s => s.trim()).filter(Boolean);
  return [];
}

export const learnToolDef = {
  name: 'arra_learn',
  description: 'Add a new pattern or learning to the Oracle knowledge base. Creates a markdown file in ψ/memory/learnings/ and indexes it.',
  inputSchema: {
    type: 'object',
    properties: {
      pattern: {
        type: 'string',
        description: 'The pattern or learning to add (can be multi-line)'
      },
      source: {
        type: 'string',
        description: 'Optional source attribution (defaults to "Oracle Learn")'
      },
      concepts: {
        type: 'array',
        items: { type: 'string' },
        description: 'Optional concept tags (e.g., ["git", "safety", "trust"])'
      },
      project: {
        type: 'string',
        description: 'Source project. Accepts: "github.com/owner/repo", "owner/repo", local path with ghq/Code prefix, or GitHub URL. Auto-normalized to "github.com/owner/repo" format.'
      }
    },
    required: ['pattern']
  }
};

// ============================================================================
// Pure helper functions (exported for testing)
// ============================================================================

/**
 * Known-project whitelist for arra_learn input validation.
 *
 * Pattern (2026-04-21 brew-ops session): four project-field typos in five days
 * — `cbank-bot`, `bank-bot<` (stray bracket), `kokarat/kokarat` (repo name == owner),
 * `pure-bot` — each created a phantom project entry that needed manual cleanup +
 * arra_supersede chain. Strict whitelist catches them at the MCP boundary before
 * the bad write lands. New projects are rare; adding one means a one-line edit
 * here + a code review (which is desirable provenance for a new vault namespace).
 *
 * All values lowercase because normalizeProject() lowercases its output.
 */
export const KNOWN_PROJECTS = new Set<string>([
  'github.com/soul-brews-studio/arra-oracle-v3',
  'github.com/soul-brews-studio/arra-oracle-v2',  // legacy
  'github.com/soul-brews-studio/maw-js',
  'github.com/soul-brews-studio/oracle-studio',
  'github.com/soul-brews-studio/ui-studio-oracle-studio',  // canonical name on github
  'github.com/kokarat/mobiz-payment-gateway',
  'github.com/kokarat/bank-bot',
  'github.com/kxlahsimx09/mb_agent_oracle_memory',
]);

/**
 * Levenshtein edit distance — used to suggest the closest known project when
 * a typo'd one is rejected. Tiny DP; both inputs are short paths so quadratic
 * cost is irrelevant.
 */
export function levenshtein(a: string, b: string): number {
  if (a === b) return 0;
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  const prev = new Array(b.length + 1);
  for (let j = 0; j <= b.length; j++) prev[j] = j;
  for (let i = 1; i <= a.length; i++) {
    let curr = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      const next = Math.min(curr + 1, prev[j] + 1, prev[j - 1] + cost);
      prev[j - 1] = curr;
      curr = next;
    }
    prev[b.length] = curr;
  }
  return prev[b.length];
}

/**
 * Find the closest known project to an unknown input — for a helpful "did you
 * mean?" suggestion in the rejection error. Returns null if every known project
 * is more than `maxDist` edits away (meaning the input is more likely a brand-new
 * project than a typo, and the operator should add it to KNOWN_PROJECTS).
 */
export function suggestClosestProject(input: string, maxDist: number = 6): string | null {
  let bestDist = Infinity;
  let bestMatch: string | null = null;
  for (const known of KNOWN_PROJECTS) {
    const d = levenshtein(input, known);
    if (d < bestDist) {
      bestDist = d;
      bestMatch = known;
    }
  }
  return bestDist <= maxDist ? bestMatch : null;
}

/**
 * Validate a normalized project string against the known-project whitelist.
 * Returns null for valid (or null/universal) input; throws with a helpful
 * suggestion otherwise. See KNOWN_PROJECTS docstring for rationale.
 */
export function validateProjectInput(project: string | null): void {
  if (project === null) return;             // universal docs allowed
  if (KNOWN_PROJECTS.has(project)) return;  // known
  const suggestion = suggestClosestProject(project);
  const knownList = Array.from(KNOWN_PROJECTS).sort().join('\n  - ');
  const suggestLine = suggestion
    ? `\n\nDid you mean: ${suggestion}?`
    : '\n\n(No close match found — if this is a genuinely new project, add it to KNOWN_PROJECTS in src/tools/learn.ts.)';
  throw new Error(
    `Unknown project: ${project}` +
    suggestLine +
    `\n\nKnown projects:\n  - ${knownList}`
  );
}

/**
 * Normalize project input to "github.com/owner/repo" format.
 * Accepts: github.com/owner/repo, owner/repo, GitHub URLs, local ghq paths.
 */
export function normalizeProject(input?: string): string | null {
  if (!input) return null;

  // Already normalized
  if (input.match(/^github\.com\/[^\/]+\/[^\/]+$/)) {
    return input.toLowerCase();
  }

  // GitHub URL
  const urlMatch = input.match(/https?:\/\/github\.com\/([^\/]+\/[^\/]+)/);
  if (urlMatch) return `github.com/${urlMatch[1].replace(/\.git$/, '')}`.toLowerCase();

  // Local path with github.com
  const pathMatch = input.match(/github\.com\/([^\/]+\/[^\/]+)/);
  if (pathMatch) return `github.com/${pathMatch[1]}`.toLowerCase();

  // Short format: owner/repo
  const shortMatch = input.match(/^([^\/\s]+\/[^\/\s]+)$/);
  if (shortMatch) return `github.com/${shortMatch[1]}`.toLowerCase();

  return null;
}

export interface FrontmatterStripResult {
  /** Pattern with any outer frontmatter block + trailing auto-footer removed. */
  cleanPattern: string;
  /** True if we actually found and stripped a frontmatter block. */
  stripped: boolean;
  /** `title:` value from the stripped frontmatter if non-empty and not `---`. */
  extractedTitle: string | null;
}

/**
 * Guard against the "arra_learn double-wrap" bug: agents occasionally pass a
 * pattern that already contains a markdown frontmatter block (e.g. pasting a
 * pre-formatted doc or a prior arra_learn output). Without this guard the
 * handler wraps its own frontmatter around the pre-wrapped body, producing
 * files with `title: ---`, a `_title-*` filename slug, and nested frontmatter
 * (caught by scripts/verify.sh in the vault as "arra_learn double-wrap bug").
 *
 * When we detect the pattern, strip the outer block (and the trailing
 * `*Added via Oracle Learn*` auto-footer if it rode along) and return the
 * bare body plus the title we recovered so the caller can seed slug/title
 * from something meaningful instead of `---`.
 */
export function stripFrontmatterWrap(pattern: string): FrontmatterStripResult {
  const unchanged: FrontmatterStripResult = { cleanPattern: pattern, stripped: false, extractedTitle: null };
  if (!pattern.startsWith('---\n') && !pattern.startsWith('---\r\n')) return unchanged;

  // normalize CRLF so line-level matches don't need to handle trailing \r
  const lines = pattern.replace(/\r\n?/g, '\n').split('\n');
  const closeLimit = Math.min(lines.length, 30);
  let closeIdx = -1;
  for (let i = 1; i < closeLimit; i++) {
    if (lines[i].trimEnd() === '---') { closeIdx = i; break; }
  }
  if (closeIdx === -1) return unchanged;

  let extractedTitle: string | null = null;
  for (let i = 1; i < closeIdx; i++) {
    const m = lines[i].match(/^title:\s*(.*)$/);
    if (m) {
      const raw = m[1].trim();
      if (raw && raw !== '---') extractedTitle = raw;
      break;
    }
  }

  let bodyStart = closeIdx + 1;
  while (bodyStart < lines.length && lines[bodyStart].trim() === '') bodyStart++;

  let bodyEnd = lines.length;
  while (bodyEnd > bodyStart && lines[bodyEnd - 1].trim() === '') bodyEnd--;
  if (bodyEnd > bodyStart && lines[bodyEnd - 1].trim() === '*Added via Oracle Learn*') {
    bodyEnd--;
    while (bodyEnd > bodyStart && lines[bodyEnd - 1].trim() === '') bodyEnd--;
    if (bodyEnd > bodyStart && lines[bodyEnd - 1].trim() === '---') bodyEnd--;
    while (bodyEnd > bodyStart && lines[bodyEnd - 1].trim() === '') bodyEnd--;
  }

  const cleanPattern = lines.slice(bodyStart, bodyEnd).join('\n');
  return { cleanPattern, stripped: true, extractedTitle };
}

/**
 * Extract project from source field (fallback).
 * Handles "arra_learn from github.com/owner/repo" and "rrr: org/repo" formats.
 */
export function extractProjectFromSource(source?: string): string | null {
  if (!source) return null;

  const oracleLearnMatch = source.match(/from\s+(github\.com\/[^\/\s]+\/[^\/\s]+)/);
  if (oracleLearnMatch) return oracleLearnMatch[1].toLowerCase();

  const rrrMatch = source.match(/^rrr:\s*([^\/\s]+\/[^\/\s]+)/);
  if (rrrMatch) return `github.com/${rrrMatch[1]}`.toLowerCase();

  const directMatch = source.match(/(github\.com\/[^\/\s]+\/[^\/\s]+)/);
  if (directMatch) return directMatch[1].toLowerCase();

  return null;
}

// ============================================================================
// Handler
// ============================================================================

export async function handleLearn(ctx: ToolContext, input: OracleLearnInput): Promise<ToolResponse> {
  const { pattern: rawPattern, source, concepts, project: projectInput } = input;
  const now = new Date();
  const dateStr = now.toISOString().split('T')[0];

  // Defend against double-wrap: if pattern is pre-wrapped markdown, peel the
  // outer frontmatter off and reuse its title so slug/title aren't derived
  // from the literal string `---`.
  const stripResult = stripFrontmatterWrap(rawPattern);
  const pattern = stripResult.cleanPattern;
  const slugSource = stripResult.extractedTitle ?? pattern;

  const slug = slugSource
    .substring(0, 50)
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, '')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');

  const filename = `${dateStr}_${slug}.md`;

  // Resolve vault root for central writes
  const vault = getVaultPsiRoot();
  if ('needsInit' in vault) console.error(`[Vault] ${vault.hint}`);
  const vaultRoot = 'path' in vault ? vault.path : null;

  const project = normalizeProject(projectInput)
    || extractProjectFromSource(source)
    || detectProject(ctx.repoRoot);

  // Reject project-field typos at the MCP boundary (see KNOWN_PROJECTS docstring).
  // Only validates explicit `projectInput` — extractProjectFromSource and
  // detectProject derive from trusted sources (source string + cwd) and don't
  // share the typo failure mode that arra_learn(project=...) hand-typing does.
  if (projectInput) {
    const normalized = normalizeProject(projectInput);
    validateProjectInput(normalized);
  }

  const projectDir = (project || '_universal').toLowerCase();

  let filePath: string;
  let sourceFileRel: string;
  if (vaultRoot) {
    const dir = path.join(vaultRoot, projectDir, 'ψ', 'memory', 'learnings');
    fs.mkdirSync(dir, { recursive: true });
    filePath = path.join(dir, filename);
    sourceFileRel = `${projectDir}/ψ/memory/learnings/${filename}`;
  } else {
    // Write to canonical REPO_ROOT, not ctx.repoRoot (the MCP server's cwd):
    // the dashboard's /api/file resolves source_file against REPO_ROOT, so
    // writing relative to cwd produces "local file not found" (#557).
    const dir = path.join(REPO_ROOT, 'ψ/memory/learnings');
    fs.mkdirSync(dir, { recursive: true });
    filePath = path.join(dir, filename);
    sourceFileRel = `ψ/memory/learnings/${filename}`;
  }

  if (fs.existsSync(filePath)) {
    throw new Error(`File already exists: ${filename}`);
  }

  const title = (stripResult.extractedTitle ?? pattern.split('\n')[0]).substring(0, 80);
  const conceptsList = coerceConcepts(concepts);
  const frontmatter = [
    '---',
    `title: ${title}`,
    conceptsList.length > 0 ? `tags: [${conceptsList.join(', ')}]` : 'tags: []',
    `created: ${dateStr}`,
    `source: ${source || 'Oracle Learn'}`,
    ...(project ? [`project: ${project}`] : []),
    '---',
    '',
    `# ${title}`,
    '',
    pattern,
    '',
    '---',
    '*Added via Oracle Learn*',
    ''
  ].join('\n');

  fs.writeFileSync(filePath, frontmatter, 'utf-8');

  const id = `learning_${dateStr}_${slug}`;

  ctx.db.insert(oracleDocuments).values({
    id,
    type: 'learning',
    sourceFile: sourceFileRel,
    concepts: JSON.stringify(conceptsList),
    createdAt: now.getTime(),
    updatedAt: now.getTime(),
    indexedAt: now.getTime(),
    origin: null,
    project,
    createdBy: 'arra_learn',
  }).run();

  // FTS5 has no unique constraint on id — delete-then-insert to be idempotent.
  ctx.sqlite.prepare(`DELETE FROM oracle_fts WHERE id = ?`).run(id);
  ctx.sqlite.prepare(`
    INSERT INTO oracle_fts (id, content, concepts)
    VALUES (?, ?, ?)
  `).run(id, frontmatter, conceptsList.join(' '));

  // Inline vector embedding — keep DB + lancedb in step so arra_search hybrid
  // mode works immediately without a follow-up `bun run index-model`. Graceful
  // fallback: if the embedder is unreachable (e.g. Ollama down) we log and
  // carry on — the FTS row above is still searchable.
  //
  // Must use `ensureVectorStoreConnected` (not `getVectorStoreByModel`) so the
  // background LanceDB connect promise is awaited before `addDocuments` runs.
  // Prior to this, a fresh MCP process's first `arra_learn` call would race the
  // connect and throw "LanceDB not connected", silently writing to FTS/disk only.
  let embeddingStatus: 'ok' | 'skipped' | 'failed' = 'skipped';
  try {
    const model = process.env.ORACLE_EMBEDDING_MODEL || 'bge-m3';
    const vectorStore = await ensureVectorStoreConnected(model);
    await vectorStore.addDocuments([{
      id,
      document: frontmatter,
      metadata: {
        type: 'learning',
        source_file: sourceFileRel,
        project: project || '',
        concepts: conceptsList.join(','),
      },
    }]);
    embeddingStatus = 'ok';
  } catch (err) {
    embeddingStatus = 'failed';
    console.warn(`[arra_learn] vector embedding failed for ${id}: ${err instanceof Error ? err.message : String(err)}`);
    console.warn(`[arra_learn] document still searchable via FTS5; run 'bun src/scripts/index-model.ts <model>' later to backfill vectors`);
  }

  const warnings = stripResult.stripped
    ? ['`pattern` began with a markdown frontmatter block and was unwrapped before indexing. ' +
       'arra_learn generates its own frontmatter — pass prose in `pattern`, not a pre-formatted doc.']
    : undefined;

  return {
    content: [{
      type: 'text',
      text: JSON.stringify({
        success: true,
        file: sourceFileRel,
        id,
        embedding: embeddingStatus,
        message: `Pattern added to Oracle knowledge base${vaultRoot ? ' (vault)' : ''}${embeddingStatus === 'failed' ? ' — vector embedding failed, see server log' : ''}`,
        ...(warnings ? { warnings } : {}),
      }, null, 2)
    }]
  };
}

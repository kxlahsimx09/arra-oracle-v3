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

/**
 * Coerce concepts to string[] — handles array, JSON-stringified array, comma
 * string, or undefined from MCP input.
 *
 * The string-input path is more nuanced than it looks. Some MCP transports
 * forward an `array<string>` argument as a JSON string (`'["a","b"]'`) rather
 * than a true array. Comma-splitting that string treats every JSON syntax
 * character (`[`, `"`, `]`) as part of the values, producing entries like
 * `'["a"'` and `'"b"]'`. The corruption then breaks downstream LIKE queries
 * (e.g. `concepts LIKE '%"brew-ops"%'` no longer matches `[\"brew-ops\"`)
 * and role-tag extraction (`extractRoleFromConcepts` sees `'["brew-ops"'`,
 * not `'brew-ops'`).
 *
 * Detection logic: if a string starts with `[` and ends with `]`, try
 * `JSON.parse` first; only fall back to comma-split when parse fails.
 *
 * Discovered 2026-04-29 brew-ops smoke test: filed `arra_learn` with
 * `concepts: ["brew-ops", "repo:arra-oracle-v3", ...]` and got back a
 * response without `trace_link_hint`. Inspecting the DB row showed the
 * concepts column stored as `["[\"brew-ops\"","\"repo:arra-oracle-v3\"",...]`
 * — proof the MCP transport had stringified the array and the comma-split
 * fallback had butchered it.
 */
export function coerceConcepts(concepts: unknown): string[] {
  if (Array.isArray(concepts)) return concepts.map(String);
  if (typeof concepts === 'string') {
    const trimmed = concepts.trim();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      try {
        const parsed = JSON.parse(trimmed);
        if (Array.isArray(parsed)) return parsed.map(String);
      } catch {
        // Not valid JSON — fall through to comma split.
      }
    }
    return concepts.split(',').map(s => s.trim()).filter(Boolean);
  }
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
 * Baseline known-project set for arra_learn input validation.
 *
 * Pattern (2026-04-21 brew-ops session): four project-field typos in five days
 * — `cbank-bot`, `bank-bot<` (stray bracket), `kokarat/kokarat` (repo name == owner),
 * `pure-bot` — each created a phantom project entry that needed manual cleanup +
 * arra_supersede chain. Strict whitelist catches them at the MCP boundary before
 * the bad write lands.
 *
 * ## Baseline vs runtime-effective set
 *
 * `KNOWN_PROJECTS` is the **baseline** — a safety-net hard-coded list that
 * survives regardless of filesystem state. The **runtime-effective** whitelist
 * is `getKnownProjects()`, which unions this baseline with project slugs
 * discovered from fleet JSON files (`.agent/fleet/*.json`) in the central
 * memory repo. That means adding a new repo no longer requires a code PR:
 * dropping a fleet JSON in place is sufficient (added 2026-04-22 brew-ops,
 * after `kxlahsimx09/mb-next-payment-gateway` blocked on this exact friction).
 *
 * The baseline still exists because:
 *   - Cold-start machines may not have the central memory cloned yet.
 *   - Legacy repos (e.g. `arra-oracle-v2`) have no fleet JSON.
 *   - If fleet scan fails, arra_learn stays functional on baseline entries.
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
 * Derive additional project slugs from fleet JSON files in the central memory repo.
 *
 * Fleet files at `<central>/github.com/<owner>/<repo>/.agent/fleet/*.json` declare
 * `project_repos: ["owner/repo", ...]` as part of the maw tmux-window config for
 * each repo. Unioning these with the baseline lets a new repo register purely by
 * sitting in the central memory repo — the same act that activates an agent there.
 *
 * Returns `[]` (falls through to baseline only) when:
 *   - `vault_repo` setting is unconfigured (first-time setup).
 *   - Central memory is configured but not yet cloned locally.
 *   - `<central>/github.com/` does not exist (no per-repo scaffold yet).
 *
 * Malformed individual fleet JSONs are skipped silently; other files still contribute.
 * Slugs that don't match `owner/repo` shape are dropped.
 *
 * Uncached worker — the public entry point is `getKnownProjects()`.
 */
function deriveFleetProjects(): string[] {
  const vault = getVaultPsiRoot();
  if ('needsInit' in vault) return [];
  const githubRoot = path.join(vault.path, 'github.com');
  if (!fs.existsSync(githubRoot)) return [];

  const results: string[] = [];
  const partPattern = /^[\w.-]+$/;

  let owners: string[];
  try { owners = fs.readdirSync(githubRoot); } catch { return []; }
  for (const owner of owners) {
    const ownerDir = path.join(githubRoot, owner);
    try {
      if (!fs.statSync(ownerDir).isDirectory()) continue;
    } catch { continue; }
    let repos: string[];
    try { repos = fs.readdirSync(ownerDir); } catch { continue; }
    for (const repo of repos) {
      const fleetDir = path.join(ownerDir, repo, '.agent', 'fleet');
      if (!fs.existsSync(fleetDir)) continue;
      let entries: string[];
      try { entries = fs.readdirSync(fleetDir); } catch { continue; }
      for (const entry of entries) {
        if (!entry.endsWith('.json')) continue;
        const file = path.join(fleetDir, entry);
        try {
          const raw = fs.readFileSync(file, 'utf-8');
          const json = JSON.parse(raw);
          const declared = Array.isArray(json?.project_repos) ? json.project_repos : [];
          for (const slug of declared) {
            if (typeof slug !== 'string') continue;
            const parts = slug.split('/');
            if (parts.length !== 2) continue;
            if (!parts.every((p: string) => partPattern.test(p))) continue;
            results.push(`github.com/${slug}`.toLowerCase());
          }
        } catch { /* skip malformed fleet JSON; siblings still count */ }
      }
    }
  }
  return results;
}

let cachedKnownProjects: Set<string> | null = null;

/**
 * Runtime-effective known-project whitelist: `KNOWN_PROJECTS` ∪ fleet-derived.
 *
 * Cached after first call — fleet JSONs change rarely and requiring an MCP-server
 * restart to pick up a new one is cheaper than re-scanning on every arra_learn.
 * Tests reset via `_resetKnownProjectsCacheForTests()`.
 */
export function getKnownProjects(): Set<string> {
  if (cachedKnownProjects) return cachedKnownProjects;
  const result = new Set(KNOWN_PROJECTS);
  for (const slug of deriveFleetProjects()) result.add(slug);
  cachedKnownProjects = result;
  return result;
}

/** Reset the `getKnownProjects()` cache. Exported for test isolation, not runtime. */
export function _resetKnownProjectsCacheForTests(): void {
  cachedKnownProjects = null;
}

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
 * project than a typo, and the operator should register it via fleet JSON —
 * see `getKnownProjects()` docstring).
 */
export function suggestClosestProject(input: string, maxDist: number = 6): string | null {
  let bestDist = Infinity;
  let bestMatch: string | null = null;
  for (const known of getKnownProjects()) {
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
 * suggestion otherwise. See `getKnownProjects()` docstring for the baseline-
 * plus-fleet-derived semantics, and `KNOWN_PROJECTS` docstring for rationale.
 */
export function validateProjectInput(project: string | null): void {
  if (project === null) return;          // universal docs allowed
  const known = getKnownProjects();
  if (known.has(project)) return;        // known (baseline or fleet-derived)
  const suggestion = suggestClosestProject(project);
  const knownList = Array.from(known).sort().join('\n  - ');
  const suggestLine = suggestion
    ? `\n\nDid you mean: ${suggestion}?`
    : '\n\n(No close match found — to register a genuinely new project, add a fleet JSON at <central>/github.com/<owner>/<repo>/.agent/fleet/*.json with `project_repos: ["<owner>/<repo>"]` and restart the MCP server. For legacy repos without an .agent/ directory, add the slug to KNOWN_PROJECTS in src/tools/learn.ts.)';
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
 * Known agent roles in the Soul-Brews fleet. Used to identify which role filed
 * a learning so `arra_learn` can hint at trace-link candidates from the same
 * role's recent work.
 *
 * Pattern (2026-04-27 next-architect retro): `arra_trace_link` was flagged as
 * missed in 8+ consecutive retros because the trigger to call it was at retro
 * time — too late, chain context already faded. The fix mirrors what makes
 * `arra_supersede` reliably remembered: surface the candidate at the moment
 * of action (right after `arra_learn` returns), not at end-of-session reflection.
 *
 * Roles match the `tags:` / `concepts:` 3-layer convention from .agent/AGENTS.md
 * §7a layer 3 (the role-tag layer). Add new roles here when the fleet grows.
 */
export const KNOWN_ROLES = new Set<string>([
  'brew-ops',
  'system-architect',
  'technical-writer',
  'pg-writer',
  'bot-writer',
  'tester',
  'pg-tester',
]);

/**
 * Pull the role tag out of a concepts list. Returns the first concept that
 * matches `KNOWN_ROLES`, or null when no role tag is present (universal docs,
 * indexer-created entries, agents that forgot the role tag).
 *
 * Returning null cleanly skips the trace-link hint in `handleLearn` — when we
 * cannot identify the role, listing "recent same-role learnings" is meaningless.
 */
export function extractRoleFromConcepts(concepts: string[]): string | null {
  for (const c of concepts) {
    const tag = String(c).trim().toLowerCase();
    if (KNOWN_ROLES.has(tag)) return tag;
  }
  return null;
}

export interface TraceLinkCandidate {
  id: string;
  source_file: string;
  created: string;
}

/**
 * Find recent same-role learnings — candidates the just-filed learning may
 * want to chain via `arra_trace_link`. Restricts to last `days` days, filters
 * out superseded entries, and orders newest-first.
 *
 * Concepts column is JSON-encoded text (`["role","domain",...]`) so a quoted
 * substring match is enough to filter — exact-token boundary thanks to the
 * surrounding `"` chars from `JSON.stringify`. Avoids json_each() cost for a
 * read on a one-time path.
 */
export function findRecentSameRoleLearnings(
  ctx: ToolContext,
  role: string,
  excludeId: string,
  days: number = 7,
  limit: number = 5,
): TraceLinkCandidate[] {
  const since = Date.now() - days * 24 * 60 * 60 * 1000;
  // Pull more than `limit` because the same source file can show up under
  // multiple ids (arra_learn stores `learning_<date>_<slug>`, the indexer
  // re-indexes the same markdown as `learning_<full-path>_<chunk>`, and
  // chunks split a single file into _0/_2/_5/...). Dedupe by basename below
  // so the agent sees one row per real learning.
  const rows = ctx.sqlite.prepare(`
    SELECT id, source_file, created_at
    FROM oracle_documents
    WHERE type = 'learning'
      AND created_at >= ?
      AND id != ?
      AND superseded_by IS NULL
      AND concepts LIKE ?
    ORDER BY created_at DESC
    LIMIT ?
  `).all(since, excludeId, `%"${role}"%`, limit * 4) as Array<{
    id: string;
    source_file: string;
    created_at: number;
  }>;

  const seen = new Set<string>();
  const result: TraceLinkCandidate[] = [];
  for (const r of rows) {
    const basename = r.source_file.split('/').pop() ?? r.source_file;
    if (seen.has(basename)) continue;
    seen.add(basename);
    result.push({
      id: r.id,
      source_file: r.source_file,
      created: new Date(r.created_at).toISOString(),
    });
    if (result.length >= limit) break;
  }
  return result;
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

  // Surface trace-link candidates at the moment of action — same mechanism that
  // keeps `arra_supersede` reliably remembered. See KNOWN_ROLES docstring for
  // the recurring-miss pattern this addresses.
  //
  // Wording note (2026-04-29 brew-ops, thread #54): `arra_trace_link` chains
  // *traces* (UUIDs in trace_log), not learnings — chain primitive is
  // `arra_trace` first, then link. Message is explicit about all three steps so
  // agents who haven't been creating traces (e.g. mb-next had 0 traces in 30d)
  // see what they actually need to call.
  const role = extractRoleFromConcepts(conceptsList);
  const recentSameRole = role ? findRecentSameRoleLearnings(ctx, role, id) : [];
  const traceLinkHint = recentSameRole.length > 0
    ? {
        role,
        recent_same_role: recentSameRole,
        message:
          `Filed as ${role}. Found ${recentSameRole.length} recent same-role learning(s) in the last 7 days. ` +
          `If this learning chains to any of them (ratifies, supersedes, or sibling pass): ` +
          `(1) arra_trace foundLearnings=["${sourceFileRel}"] query="<this pass>" — log the session, ` +
          `(2) arra_trace_list query="<prior learning's slug>" — find the prior trace UUID, ` +
          `(3) arra_trace_link prevTraceId=<prior> nextTraceId=<this> — chain them. ` +
          `Do it before the next commit. retro-time is too late, chain context will fade.`,
      }
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
        ...(traceLinkHint ? { trace_link_hint: traceLinkHint } : {}),
      }, null, 2)
    }]
  };
}

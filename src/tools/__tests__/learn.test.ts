/**
 * Unit tests for learn helpers (pure functions).
 */

import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { normalizeProject, extractProjectFromSource, stripFrontmatterWrap, levenshtein, suggestClosestProject, validateProjectInput, KNOWN_PROJECTS, getKnownProjects, _resetKnownProjectsCacheForTests, extractRoleFromConcepts, KNOWN_ROLES, coerceConcepts } from '../learn.ts';

// ============================================================================
// normalizeProject
// ============================================================================

describe('normalizeProject', () => {
  it('should return null for empty input', () => {
    expect(normalizeProject(undefined)).toBeNull();
    expect(normalizeProject('')).toBeNull();
  });

  it('should pass through already-normalized format', () => {
    expect(normalizeProject('github.com/owner/repo')).toBe('github.com/owner/repo');
  });

  it('should normalize GitHub URLs', () => {
    expect(normalizeProject('https://github.com/owner/repo')).toBe('github.com/owner/repo');
    expect(normalizeProject('https://github.com/owner/repo.git')).toBe('github.com/owner/repo');
  });

  it('should normalize local ghq paths', () => {
    expect(normalizeProject('/Users/nat/Code/github.com/owner/repo')).toBe('github.com/owner/repo');
    expect(normalizeProject('~/Code/github.com/owner/repo/src/file.ts')).toBe('github.com/owner/repo');
  });

  it('should normalize short owner/repo format', () => {
    expect(normalizeProject('owner/repo')).toBe('github.com/owner/repo');
  });

  it('should normalize to lowercase', () => {
    expect(normalizeProject('github.com/Soul-Brews-Studio/Oracle-V2')).toBe('github.com/soul-brews-studio/oracle-v2');
    expect(normalizeProject('https://github.com/Owner/Repo')).toBe('github.com/owner/repo');
    expect(normalizeProject('Owner/Repo')).toBe('github.com/owner/repo');
  });

  it('should return null for unrecognized formats', () => {
    expect(normalizeProject('just-a-name')).toBeNull();
    expect(normalizeProject('too/many/slashes/here')).toBeNull();
  });
});

// ============================================================================
// extractProjectFromSource
// ============================================================================

describe('extractProjectFromSource', () => {
  it('should return null for empty input', () => {
    expect(extractProjectFromSource(undefined)).toBeNull();
    expect(extractProjectFromSource('')).toBeNull();
  });

  it('should extract from "arra_learn from github.com/owner/repo" format', () => {
    expect(extractProjectFromSource('arra_learn from github.com/owner/repo session 42'))
      .toBe('github.com/owner/repo');
  });

  it('should extract from "rrr: org/repo" format', () => {
    expect(extractProjectFromSource('rrr: Soul-Brews-Studio/oracle-v2'))
      .toBe('github.com/soul-brews-studio/oracle-v2');
  });

  it('should extract direct github.com reference', () => {
    expect(extractProjectFromSource('some text github.com/foo/bar more text'))
      .toBe('github.com/foo/bar');
  });

  it('should return null when no project found', () => {
    expect(extractProjectFromSource('just some random text')).toBeNull();
  });
});

// ============================================================================
// stripFrontmatterWrap — guard against the "arra_learn double-wrap" bug
// ============================================================================

describe('stripFrontmatterWrap', () => {
  it('should pass plain prose through untouched', () => {
    const result = stripFrontmatterWrap('just a paragraph describing the pattern');
    expect(result.stripped).toBe(false);
    expect(result.cleanPattern).toBe('just a paragraph describing the pattern');
    expect(result.extractedTitle).toBeNull();
  });

  it('should pass prose starting with dashes but no closing --- untouched', () => {
    const input = '---this is not actually a frontmatter block, just dashes---';
    const result = stripFrontmatterWrap(input);
    expect(result.stripped).toBe(false);
    expect(result.cleanPattern).toBe(input);
  });

  it('should strip a wrapping frontmatter block and recover the title', () => {
    const input = [
      '---',
      'title: flow — ktb-single-transfer-withdrawal — bot-side intent at a glance',
      'tags: [flow, ktb]',
      'created: 2026-04-19',
      '---',
      '',
      'One-sentence purpose: after the mobiz gateway has assigned a pending withdrawal',
      'queue item, bank-bot claims 1-5 items and executes them as one batched transfer.',
    ].join('\n');
    const result = stripFrontmatterWrap(input);
    expect(result.stripped).toBe(true);
    expect(result.extractedTitle).toBe('flow — ktb-single-transfer-withdrawal — bot-side intent at a glance');
    expect(result.cleanPattern.startsWith('One-sentence purpose')).toBe(true);
    expect(result.cleanPattern).not.toContain('---');
    expect(result.cleanPattern).not.toContain('title:');
  });

  it('should reject empty / placeholder titles like `title: ---`', () => {
    const input = ['---', 'title: ---', 'tags: []', '---', '', 'body text'].join('\n');
    const result = stripFrontmatterWrap(input);
    expect(result.stripped).toBe(true);
    expect(result.extractedTitle).toBeNull();
    expect(result.cleanPattern).toBe('body text');
  });

  it('should strip the trailing `*Added via Oracle Learn*` auto-footer', () => {
    const input = [
      '---',
      'title: my pattern',
      '---',
      '',
      '# my pattern',
      '',
      'actual body content',
      '',
      '---',
      '*Added via Oracle Learn*',
      '',
    ].join('\n');
    const result = stripFrontmatterWrap(input);
    expect(result.stripped).toBe(true);
    expect(result.cleanPattern).not.toContain('Added via Oracle Learn');
    expect(result.cleanPattern).toContain('actual body content');
  });

  it('should handle CRLF line endings', () => {
    const input = '---\r\ntitle: crlf test\r\n---\r\n\r\nbody here';
    const result = stripFrontmatterWrap(input);
    expect(result.stripped).toBe(true);
    expect(result.extractedTitle).toBe('crlf test');
  });

  it('should leave pattern unchanged if closing --- is missing within first 30 lines', () => {
    const lines = ['---', 'title: never closes'];
    for (let i = 0; i < 40; i++) lines.push(`line ${i}`);
    const input = lines.join('\n');
    const result = stripFrontmatterWrap(input);
    expect(result.stripped).toBe(false);
    expect(result.cleanPattern).toBe(input);
  });
});

// ============================================================================
// Project-typo guard (KNOWN_PROJECTS + Levenshtein + validateProjectInput)
// ============================================================================
//
// Pattern: 4 typos in 5 days (cbank-bot, bank-bot<, kokarat/kokarat, pure-bot)
// each created phantom project entries that needed manual cleanup. These tests
// pin the guard against the exact strings that slipped through.

describe('levenshtein', () => {
  it('returns 0 for identical strings', () => {
    expect(levenshtein('abc', 'abc')).toBe(0);
  });
  it('returns length for empty other side', () => {
    expect(levenshtein('', 'abc')).toBe(3);
    expect(levenshtein('abc', '')).toBe(3);
  });
  it('counts a single substitution', () => {
    expect(levenshtein('cat', 'bat')).toBe(1);
  });
  it('counts a single insertion (cbank-bot vs bank-bot = 1)', () => {
    expect(levenshtein('cbank-bot', 'bank-bot')).toBe(1);
  });
  it('counts a single insertion (bank-bot< vs bank-bot = 1)', () => {
    expect(levenshtein('bank-bot<', 'bank-bot')).toBe(1);
  });
});

describe('suggestClosestProject', () => {
  it('suggests bank-bot for cbank-bot typo', () => {
    expect(suggestClosestProject('github.com/kokarat/cbank-bot')).toBe('github.com/kokarat/bank-bot');
  });
  it('suggests bank-bot for bank-bot< stray-bracket typo', () => {
    expect(suggestClosestProject('github.com/kokarat/bank-bot<')).toBe('github.com/kokarat/bank-bot');
  });
  it('suggests bank-bot for pure-bot typo', () => {
    expect(suggestClosestProject('github.com/kokarat/pure-bot')).toBe('github.com/kokarat/bank-bot');
  });
  it('suggests mobiz-payment-gateway for kokarat/kokarat (org==repo) typo', () => {
    // kokarat/kokarat is unusual — closest known kokarat project is mobiz or bank-bot
    const suggestion = suggestClosestProject('github.com/kokarat/kokarat');
    expect(suggestion).toMatch(/^github\.com\/kokarat\//);
  });
  it('returns null when input is far from any known project', () => {
    // 30+ char gibberish — should NOT suggest anything (let it through as new)
    expect(suggestClosestProject('github.com/some-totally-new-org/some-totally-new-repo-xyz123')).toBeNull();
  });
});

describe('validateProjectInput (the guard)', () => {
  it('passes for null (universal docs)', () => {
    expect(() => validateProjectInput(null)).not.toThrow();
  });
  it('passes for known projects', () => {
    expect(() => validateProjectInput('github.com/kokarat/bank-bot')).not.toThrow();
    expect(() => validateProjectInput('github.com/kokarat/mobiz-payment-gateway')).not.toThrow();
    expect(() => validateProjectInput('github.com/soul-brews-studio/arra-oracle-v3')).not.toThrow();
  });
  it('passes for p2p-hub (registered via baseline — greenfield, no fleet JSON, thread #251)', () => {
    expect(() => validateProjectInput('github.com/kxlahsimx09/p2p-hub')).not.toThrow();
  });
  it('rejects cbank-bot typo with bank-bot suggestion', () => {
    expect(() => validateProjectInput('github.com/kokarat/cbank-bot')).toThrow(/Did you mean: github\.com\/kokarat\/bank-bot/);
  });
  it('rejects bank-bot< stray-bracket typo with bank-bot suggestion', () => {
    expect(() => validateProjectInput('github.com/kokarat/bank-bot<')).toThrow(/Did you mean: github\.com\/kokarat\/bank-bot/);
  });
  it('rejects kokarat/kokarat typo (whatever the suggestion)', () => {
    expect(() => validateProjectInput('github.com/kokarat/kokarat')).toThrow(/Unknown project/);
  });
  it('rejects pure-bot typo with bank-bot suggestion', () => {
    expect(() => validateProjectInput('github.com/kokarat/pure-bot')).toThrow(/Did you mean: github\.com\/kokarat\/bank-bot/);
  });
  it('rejects truly-new far-distance project (points operator to fleet JSON)', () => {
    // Per current design, ALL non-whitelisted projects throw — the error message
    // directs the operator to the primary registration path (fleet JSON) with
    // baseline KNOWN_PROJECTS as the legacy fallback.
    expect(() => validateProjectInput('github.com/some-totally-new-org/some-totally-new-repo-xyz123'))
      .toThrow(/register a genuinely new project/);
  });
});

// ============================================================================
// Thread #221 finding D — arra_learn(project=...) resolution is NOT broken.
// ============================================================================
//
// wt-17 (thread #219 msg 969) saw a learning it filed land in _universal/ with
// no `project:` frontmatter. The question (thread #221): code bug, or only the
// stale running server (PID 5859, up since May 17)? Evidence makes it NEITHER:
//   - Current source resolves the exact input (this block).
//   - The live PID-5859 server reproduced a project-first write with the same
//     input (2026-05-23 ~15:40 GMT+7) — so it is not a stale-server gap either.
//   - The actual cause was caller-side: wt-17's `project` argument leaked into
//     the `pattern` body as literal `</pattern><parameter name="project">…`
//     tool-call markup (visible on disk in
//     _universal/ψ/.../2026-05-23_arralearn-with-a-project-writes-the-learning.md),
//     so no `project` value reached handleLearn → correct _universal fallback.
// This block pins the part the server owns: when the handler DOES receive the
// input, it resolves it and the whitelist accepts it (project-first, not
// _universal). No D code change; the malformed-call mode is client-side.

describe('finding D: explicit project= resolves (handler-side is correct)', () => {
  const WT17_INPUT = 'github.com/Soul-Brews-Studio/arra-oracle-v3'; // the slug wt-17 intended
  const RESOLVED = 'github.com/soul-brews-studio/arra-oracle-v3';

  it('normalizeProject resolves the mixed-case input to the canonical slug', () => {
    expect(normalizeProject(WT17_INPUT)).toBe(RESOLVED);
  });

  it('validateProjectInput accepts the normalized slug (whitelist hit, no throw)', () => {
    // handleLearn validates normalizeProject(projectInput); a hit here means the
    // resolved project survives to projectDir + the `project:` frontmatter line,
    // so the write lands project-first, not in _universal/.
    expect(() => validateProjectInput(normalizeProject(WT17_INPUT))).not.toThrow();
  });
});

// ============================================================================
// getKnownProjects (baseline ∪ fleet-derived)
// ============================================================================

describe('getKnownProjects', () => {
  beforeEach(() => _resetKnownProjectsCacheForTests());
  afterEach(() => _resetKnownProjectsCacheForTests());

  it('includes every baseline KNOWN_PROJECTS entry', () => {
    const known = getKnownProjects();
    for (const p of KNOWN_PROJECTS) {
      expect(known.has(p)).toBe(true);
    }
  });

  it('returns a superset of the baseline (size >= baseline size)', () => {
    const known = getKnownProjects();
    expect(known.size).toBeGreaterThanOrEqual(KNOWN_PROJECTS.size);
  });

  it('caches after first call (reference equality)', () => {
    const a = getKnownProjects();
    const b = getKnownProjects();
    expect(a).toBe(b);
  });

  it('reset lets subsequent call rebuild (returns a fresh Set instance)', () => {
    const a = getKnownProjects();
    _resetKnownProjectsCacheForTests();
    const b = getKnownProjects();
    expect(a).not.toBe(b);
    // Content-equivalent: both contain every baseline entry.
    for (const p of KNOWN_PROJECTS) {
      expect(b.has(p)).toBe(true);
    }
  });
});

// ============================================================================
// extractRoleFromConcepts — feeds the trace-link hint in handleLearn
// ============================================================================
//
// Pattern (2026-04-27 next-architect retro): arra_trace_link missed in 8+
// consecutive retros. Hint surfaces candidates at learn-time; needs a reliable
// way to pick the role from the 3-layer tag list.

describe('extractRoleFromConcepts', () => {
  it('returns null for an empty concepts list', () => {
    expect(extractRoleFromConcepts([])).toBeNull();
  });

  it('returns null when no concept matches a known role', () => {
    expect(extractRoleFromConcepts(['memory', 'fts5', 'gotcha'])).toBeNull();
  });

  it('picks the role tag regardless of position', () => {
    expect(extractRoleFromConcepts(['repo:cross', 'memory', 'brew-ops'])).toBe('brew-ops');
    expect(extractRoleFromConcepts(['system-architect', 'next', 'adr'])).toBe('system-architect');
  });

  it('picks the first role when multiple are tagged (cross-role learnings)', () => {
    // Real example: 2026-04-16 maw-fleet gotcha tagged both brew-ops + tester.
    expect(extractRoleFromConcepts(['brew-ops', 'tester', 'fleet'])).toBe('brew-ops');
  });

  it('normalizes case before matching', () => {
    expect(extractRoleFromConcepts(['Brew-Ops', 'memory'])).toBe('brew-ops');
  });

  it('every entry in KNOWN_ROLES is picked up by the extractor', () => {
    for (const role of KNOWN_ROLES) {
      expect(extractRoleFromConcepts(['some-domain', role])).toBe(role);
    }
  });
});

// ============================================================================
// coerceConcepts — handles MCP transport quirks
// ============================================================================
//
// Pattern (2026-04-29 brew-ops smoke test): MCP transport delivered an
// array<string> argument as a JSON-stringified array ('["a","b"]'). The old
// fallback comma-split butchered it into ['["a"', '"b"]'], which then broke
// the LIKE query for trace_link_hint and role-tag extraction. Tests pin the
// fix.

describe('coerceConcepts', () => {
  it('returns empty array for undefined / non-string-non-array input', () => {
    expect(coerceConcepts(undefined)).toEqual([]);
    expect(coerceConcepts(null)).toEqual([]);
    expect(coerceConcepts(42)).toEqual([]);
    expect(coerceConcepts({})).toEqual([]);
  });

  it('passes a true array through, coercing entries to string', () => {
    expect(coerceConcepts(['a', 'b', 'c'])).toEqual(['a', 'b', 'c']);
    expect(coerceConcepts(['brew-ops', 'memory'])).toEqual(['brew-ops', 'memory']);
  });

  it('parses JSON-stringified array (the MCP transport case)', () => {
    expect(coerceConcepts('["brew-ops","repo:arra-oracle-v3","memory"]'))
      .toEqual(['brew-ops', 'repo:arra-oracle-v3', 'memory']);
  });

  it('parses JSON-stringified array with whitespace + escaped quotes', () => {
    expect(coerceConcepts('  ["a", "b", "c"]  ')).toEqual(['a', 'b', 'c']);
  });

  it('falls back to comma-split when string looks like comma list, not JSON', () => {
    expect(coerceConcepts('git,safety,trust')).toEqual(['git', 'safety', 'trust']);
    expect(coerceConcepts('a, b, c')).toEqual(['a', 'b', 'c']);
  });

  it('falls back to comma-split when JSON parse fails despite [...] shape', () => {
    // Looks like a JSON array but isn't valid — comma-split is best effort.
    expect(coerceConcepts('[broken,json]')).toEqual(['[broken', 'json]']);
  });

  it('coerces JSON-array entries that aren\'t strings into strings', () => {
    expect(coerceConcepts('[1, 2, 3]')).toEqual(['1', '2', '3']);
  });

  it('handles empty inputs gracefully', () => {
    expect(coerceConcepts('')).toEqual([]);
    expect(coerceConcepts('[]')).toEqual([]);
    expect(coerceConcepts([])).toEqual([]);
  });

  it('regression: stringified array does NOT produce the old butchered output', () => {
    // The bug: comma-splitting '["brew-ops","memory"]' produced
    // ['["brew-ops"', '"memory"]']. After fix, must produce clean tokens.
    const input = '["brew-ops","memory"]';
    const out = coerceConcepts(input);
    expect(out).not.toContain('["brew-ops"');
    expect(out).not.toContain('"memory"]');
    expect(out).toEqual(['brew-ops', 'memory']);
  });
});

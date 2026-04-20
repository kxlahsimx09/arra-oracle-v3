/**
 * Unit tests for learn helpers (pure functions).
 */

import { describe, it, expect } from 'bun:test';
import { normalizeProject, extractProjectFromSource, stripFrontmatterWrap } from '../learn.ts';

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

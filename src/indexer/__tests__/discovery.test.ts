/**
 * Unit tests for project discovery.
 *
 * Regression cover for thread #221 finding C: _universal/ψ learnings (filed via
 * arra_learn with no resolvable project) must be discovered by the batch
 * reindexer, else a from-scratch rebuild silently drops them.
 */

import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { discoverProjectPsiDirs, inferProjectFromPath } from '../discovery.ts';

const PSI = 'ψ'; // ψ — matches the literal used in discovery.ts

let root: string;

beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'oracle-discovery-'));
});

afterEach(() => {
  fs.rmSync(root, { recursive: true, force: true });
});

/** Create <root>/<segments...> as a directory. */
function mkdir(...segments: string[]): string {
  const dir = path.join(root, ...segments);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

describe('discoverProjectPsiDirs', () => {
  it('discovers project-first {host}/{org}/{repo}/ψ dirs', () => {
    const gh = mkdir('github.com', 'soul-brews-studio', 'arra-oracle-v3', PSI);
    mkdir('gitlab.com', 'org', 'repo', PSI);

    const dirs = discoverProjectPsiDirs(root);

    expect(dirs).toContain(gh);
    expect(dirs.length).toBe(2);
  });

  it('also discovers the _universal/ψ bucket (finding C)', () => {
    mkdir('github.com', 'soul-brews-studio', 'arra-oracle-v3', PSI);
    const universal = mkdir('_universal', PSI);

    const dirs = discoverProjectPsiDirs(root);

    expect(dirs).toContain(universal);
  });

  it('discovers _universal/ψ even when no host dirs exist at all', () => {
    const universal = mkdir('_universal', PSI);

    const dirs = discoverProjectPsiDirs(root);

    expect(dirs).toEqual([universal]);
  });

  it('omits _universal when the ψ subdir is absent', () => {
    // _universal/ exists but has no ψ child — must not be returned.
    mkdir('_universal', 'not-psi');

    const dirs = discoverProjectPsiDirs(root);

    expect(dirs).toEqual([]);
  });

  it('returns [] for an empty vault root', () => {
    expect(discoverProjectPsiDirs(root)).toEqual([]);
  });
});

describe('inferProjectFromPath — _universal stays project-less', () => {
  it('returns null for a _universal/ψ path (universal learning, no project)', () => {
    // Universal learnings legitimately have no project; the parser stores
    // project: undefined for them. Confirm discovery surfacing them does not
    // accidentally infer a bogus project from the path.
    expect(inferProjectFromPath(`_universal/${PSI}/memory/learnings/x.md`)).toBeNull();
  });

  it('still infers project for a real project-first path', () => {
    expect(
      inferProjectFromPath(`github.com/Soul-Brews-Studio/arra-oracle-v3/${PSI}/memory/learnings/x.md`)
    ).toBe('github.com/soul-brews-studio/arra-oracle-v3');
  });
});

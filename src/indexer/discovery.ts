/**
 * Project discovery and path inference
 */

import fs from 'fs';
import path from 'path';

/**
 * Discover project-first psi directories in vault.
 * Scans {host}/{org}/{repo}/psi/ at repoRoot for github.com, gitlab.com, bitbucket.org,
 * plus the _universal/psi/ bucket for learnings filed with no resolvable project.
 * Returns absolute paths to each psi directory.
 */
export function discoverProjectPsiDirs(repoRoot: string): string[] {
  const dirs: string[] = [];
  const hosts = ['github.com', 'gitlab.com', 'bitbucket.org'];

  for (const host of hosts) {
    const hostDir = path.join(repoRoot, host);
    if (!fs.existsSync(hostDir)) continue;

    for (const org of fs.readdirSync(hostDir)) {
      const orgDir = path.join(hostDir, org);
      if (!fs.statSync(orgDir).isDirectory()) continue;

      for (const repo of fs.readdirSync(orgDir)) {
        const psiDir = path.join(orgDir, repo, '\u03c8');
        if (fs.existsSync(psiDir) && fs.statSync(psiDir).isDirectory()) {
          dirs.push(psiDir);
        }
      }
    }
  }

  // _universal/\u03c8 holds learnings filed via arra_learn with no resolvable
  // project \u2014 projectDir falls back to '_universal' in src/tools/learn.ts.
  // It is not a {host}/{org}/{repo} path, so the host loop above skips it; without
  // this the batch reindexer never sees those files, leaving them index-only, and
  // a from-scratch rebuild silently drops them (e.g. the five 2026-05-21
  // orchestrator-pattern learnings). Thread #221 (finding C).
  const universalPsi = path.join(repoRoot, '_universal', '\u03c8');
  if (fs.existsSync(universalPsi) && fs.statSync(universalPsi).isDirectory()) {
    dirs.push(universalPsi);
  }

  if (dirs.length > 0) {
    console.log(`Discovered ${dirs.length} project-first \u03c8/ directories`);
  }
  return dirs;
}

/**
 * Infer project from a vault-nested path.
 * Project-first layout: "github.com/org/repo/psi/..." -> "github.com/org/repo"
 * Also supports legacy layout: "psi/memory/{category}/github.com/org/repo/..."
 */
export function inferProjectFromPath(relativePath: string): string | null {
  // Project-first layout: github.com/org/repo/psi/...
  const projectFirst = relativePath.match(
    /^(github\.com|gitlab\.com|bitbucket\.org)\/([^/]+\/[^/]+)\/\u03c8\//
  );
  if (projectFirst) {
    return `${projectFirst[1]}/${projectFirst[2]}`.toLowerCase();
  }

  // Legacy layout: psi/memory/{category}/github.com/org/repo/...
  const legacy = relativePath.match(
    /^\u03c8\/(?:memory\/(?:learnings|retrospectives)|inbox\/handoff)\/(github\.com|gitlab\.com|bitbucket\.org)\/([^/]+\/[^/]+)\//
  );
  if (legacy) {
    return `${legacy[1]}/${legacy[2]}`.toLowerCase();
  }

  return null;
}

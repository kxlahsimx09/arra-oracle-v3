/**
 * Oracle Inbox Handler
 *
 * List and preview pending handoff files from the Oracle inbox.
 */

import path from 'path';
import fs from 'fs';
import { getVaultPsiRoot } from '../vault/discovery.ts';
import type { ToolContext, ToolResponse, OracleInboxInput } from './types.ts';

export const inboxToolDef = {
  name: 'arra_inbox',
  description: 'List and preview pending handoff files from the Oracle inbox. Returns files sorted newest-first with previews.',
  inputSchema: {
    type: 'object',
    properties: {
      limit: {
        type: 'number',
        description: 'Maximum files to return (default: 10)',
        default: 10
      },
      offset: {
        type: 'number',
        description: 'Number of files to skip (for pagination)',
        default: 0
      },
      type: {
        type: 'string',
        enum: ['handoff', 'all'],
        description: 'Filter by inbox type (default: all)',
        default: 'all'
      }
    }
  }
};

// Mirror arra_handoff write targets: <vault>/<project>/ψ/inbox/handoff/ where
// project ∈ { detected slug (e.g. "github.com/owner/repo"), "_universal" },
// plus the universal root reached via repoRoot/ψ symlink.
function collectHandoffDirs(repoRoot: string): Array<{ dir: string; relBase: string }> {
  const dirs: Array<{ dir: string; relBase: string }> = [];
  const seen = new Set<string>();
  const push = (dir: string, relBase: string) => {
    if (!fs.existsSync(dir)) return;
    let real: string;
    try { real = fs.realpathSync(dir); } catch { return; }
    if (seen.has(real)) return;
    seen.add(real);
    dirs.push({ dir, relBase });
  };

  push(path.join(repoRoot, 'ψ/inbox/handoff'), 'ψ/inbox/handoff');

  const vault = getVaultPsiRoot();
  if ('path' in vault) {
    const vaultRoot = vault.path;
    push(path.join(vaultRoot, 'ψ/inbox/handoff'), 'ψ/inbox/handoff');
    push(path.join(vaultRoot, '_universal/ψ/inbox/handoff'), '_universal/ψ/inbox/handoff');
    const ghRoot = path.join(vaultRoot, 'github.com');
    if (fs.existsSync(ghRoot)) {
      for (const owner of fs.readdirSync(ghRoot)) {
        const ownerDir = path.join(ghRoot, owner);
        if (!fs.statSync(ownerDir).isDirectory()) continue;
        for (const repo of fs.readdirSync(ownerDir)) {
          push(
            path.join(ownerDir, repo, 'ψ/inbox/handoff'),
            `github.com/${owner}/${repo}/ψ/inbox/handoff`,
          );
        }
      }
    }
  }

  return dirs;
}

export async function handleInbox(ctx: ToolContext, input: OracleInboxInput): Promise<ToolResponse> {
  const { limit = 10, offset = 0, type = 'all' } = input;
  const results: Array<{ filename: string; path: string; created: string; preview: string; type: string }> = [];

  if (type === 'all' || type === 'handoff') {
    for (const { dir, relBase } of collectHandoffDirs(ctx.repoRoot)) {
      const files = fs.readdirSync(dir).filter(f => f.endsWith('.md'));
      for (const file of files) {
        const filePath = path.join(dir, file);
        const content = fs.readFileSync(filePath, 'utf-8');
        const dateMatch = file.match(/^(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2})/);
        const created = dateMatch
          ? `${dateMatch[1]}T${dateMatch[2].replace('-', ':')}:00`
          : 'unknown';

        results.push({
          filename: file,
          path: `${relBase}/${file}`,
          created,
          preview: content.substring(0, 500),
          type: 'handoff',
        });
      }
    }
  }

  // Sort newest-first by filename (ISO prefix keeps lexicographic = chronological).
  results.sort((a, b) => b.filename.localeCompare(a.filename));

  const total = results.length;
  const paginated = results.slice(offset, offset + limit);

  console.error(`[MCP:INBOX] ${total} files, returning ${paginated.length} (offset=${offset})`);

  return {
    content: [{
      type: 'text',
      text: JSON.stringify({ files: paginated, total, limit, offset }, null, 2)
    }]
  };
}

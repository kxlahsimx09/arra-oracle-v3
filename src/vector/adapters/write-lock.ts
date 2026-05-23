/**
 * Inter-process advisory write lock — the root-cause fix for LanceDB
 * manifest drift (thread #115, 4 recurrences: 2026-04-14/04-21/05-16/05-23).
 *
 * `@lancedb/lancedb@0.27.2` has no cross-process write lock. When the HTTP
 * server, an MCP instance, and the indexer share one lancedb dir, two
 * concurrent `table.add()` calls can commit a manifest version that references
 * a data fragment the other writer has not flushed yet; every subsequent
 * vector query then hits the broken manifest and silently falls back to FTS5.
 * `LanceDBAdapter.writeChain` only serializes writes *within* one process —
 * this lock closes the *inter-process* gap.
 *
 * Mechanism:
 *   - An atomic `mkdir` is the lock token (`mkdir` fails with EEXIST if the dir
 *     already exists — POSIX-atomic, no daemon needed). The holder writes an
 *     owner descriptor (pid + host + a per-acquisition token) inside it.
 *   - A stale lock — holder pid is gone, or it has been held past `staleMs` —
 *     is reclaimed via an atomic `rename`, so only one waiter can win the
 *     steal even if several detect staleness at once.
 *   - Acquisition polls with jittered backoff up to `timeoutMs`, then throws.
 *     A blocked writer fails LOUD and the caller degrades to FTS5 (keeping the
 *     canonical SQLite row) rather than deadlocking the HTTP write path.
 *   - `release` only removes the dir if we still own the token, so a writer
 *     whose lock was stolen never deletes its successor's lock.
 *
 * Same-host only by design: every Oracle writer shares one node (AGENTS §11a),
 * so `process.kill(pid, 0)` liveness checks are valid. A lock owned by another
 * host falls back to time-based staleness.
 */
import fs from 'fs';
import os from 'os';
import path from 'path';
import { randomUUID } from 'crypto';

export interface WriteLockOptions {
  /** Max time to wait to acquire before throwing (default 15000ms). */
  timeoutMs?: number;
  /** A lock older than this whose holder is gone is stolen (default 30000ms). */
  staleMs?: number;
  /** Base poll interval between acquire attempts; jittered (default 50ms). */
  pollMs?: number;
  /** Fired once when an acquire has to wait, for contention logging. */
  onContended?: (info: { waitedMs: number; holder: OwnerDescriptor | null }) => void;
}

export interface OwnerDescriptor {
  pid: number;
  host: string;
  token: string;
  acquiredAt: number;
  op?: string;
}

const DEFAULTS = { timeoutMs: 15_000, staleMs: 30_000, pollMs: 50 };

export class InterProcessWriteLock {
  private readonly lockDir: string;
  private readonly ownerFile: string;
  private readonly timeoutMs: number;
  private readonly staleMs: number;
  private readonly pollMs: number;
  private readonly onContended?: WriteLockOptions['onContended'];

  constructor(lockDir: string, opts: WriteLockOptions = {}) {
    this.lockDir = lockDir;
    this.ownerFile = path.join(lockDir, 'owner.json');
    this.timeoutMs = opts.timeoutMs ?? DEFAULTS.timeoutMs;
    this.staleMs = opts.staleMs ?? DEFAULTS.staleMs;
    this.pollMs = opts.pollMs ?? DEFAULTS.pollMs;
    this.onContended = opts.onContended;
  }

  /** Run `fn` while holding the lock; always releases, even on throw. */
  async withLock<T>(fn: () => Promise<T>, op?: string): Promise<T> {
    const token = await this.acquire(op);
    try {
      return await fn();
    } finally {
      await this.release(token);
    }
  }

  /** Acquire the lock, returning the ownership token used to release it. */
  async acquire(op?: string): Promise<string> {
    const token = randomUUID();
    const start = Date.now();
    let contendedReported = false;
    await fs.promises.mkdir(path.dirname(this.lockDir), { recursive: true });

    for (;;) {
      try {
        await fs.promises.mkdir(this.lockDir);
        const owner: OwnerDescriptor = {
          pid: process.pid, host: os.hostname(), token, acquiredAt: Date.now(), op,
        };
        await fs.promises.writeFile(this.ownerFile, JSON.stringify(owner));
        return token;
      } catch (err: any) {
        if (err?.code !== 'EEXIST') throw err;
      }

      const holder = await this.readOwner();
      if (this.isStale(holder)) {
        await this.steal();
        continue; // retry mkdir immediately after reclaiming
      }

      const waited = Date.now() - start;
      if (waited >= this.timeoutMs) {
        const held = holder
          ? ` (held by pid ${holder.pid}@${holder.host} since ` +
            `${new Date(holder.acquiredAt).toISOString()}, op=${holder.op ?? '?'})`
          : '';
        throw new Error(`[write-lock] timed out after ${waited}ms acquiring ${this.lockDir}${held}`);
      }
      if (!contendedReported && this.onContended) {
        contendedReported = true;
        this.onContended({ waitedMs: waited, holder });
      }
      // Jittered backoff: avoids a thundering herd always re-racing in lockstep.
      await sleep(this.pollMs + Math.floor(Math.random() * this.pollMs));
    }
  }

  /** Release the lock iff we still own it (guards against post-steal deletion). */
  async release(token: string): Promise<void> {
    const holder = await this.readOwner();
    if (holder && holder.token !== token) {
      console.warn(
        `[write-lock] not releasing ${this.lockDir}: now owned by token ` +
        `${holder.token} (pid ${holder.pid}), not ${token} — our lock was stolen as stale`
      );
      return;
    }
    await this.removeDir(this.lockDir);
  }

  private async readOwner(): Promise<OwnerDescriptor | null> {
    try {
      return JSON.parse(await fs.promises.readFile(this.ownerFile, 'utf8')) as OwnerDescriptor;
    } catch {
      return null; // missing / partial / corrupt → treat holder as unknown
    }
  }

  private isStale(holder: OwnerDescriptor | null): boolean {
    // Dir exists but no readable owner: either mid-acquire (writeFile not done
    // yet) or a crash before the descriptor landed. Fall back to dir mtime.
    if (!holder) return this.dirAgeMs() > this.staleMs;
    if (holder.host === os.hostname() && !pidAlive(holder.pid)) return true;
    return Date.now() - holder.acquiredAt > this.staleMs;
  }

  private dirAgeMs(): number {
    try {
      return Date.now() - fs.statSync(this.lockDir).mtimeMs;
    } catch {
      return Infinity;
    }
  }

  /** Atomically reclaim a stale lock so only one waiter wins the steal. */
  private async steal(): Promise<void> {
    const tomb = `${this.lockDir}.stale-${process.pid}-${Date.now()}`;
    try {
      await fs.promises.rename(this.lockDir, tomb);
    } catch {
      return; // ENOENT etc. → another waiter already reclaimed/released it
    }
    await this.removeDir(tomb);
  }

  private async removeDir(dir: string): Promise<void> {
    try {
      await fs.promises.rm(dir, { recursive: true });
    } catch (err: any) {
      if (err?.code !== 'ENOENT') throw err;
    }
  }
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err: any) {
    return err?.code === 'EPERM'; // exists but owned by another user
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

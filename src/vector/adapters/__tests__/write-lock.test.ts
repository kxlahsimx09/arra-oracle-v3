/**
 * Unit tests for the inter-process advisory write lock (thread #115 Phase 2).
 *
 * These exercise the real filesystem (mkdir/rename/rm under os.tmpdir) because
 * the lock's whole point is cross-process correctness — there is nothing to
 * mock. Two lock instances pointing at the same dir stand in for two processes.
 */
import { describe, test, expect, afterAll } from 'bun:test';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { randomUUID } from 'crypto';
import { InterProcessWriteLock } from '../write-lock.ts';

const ROOT = path.join(os.tmpdir(), `arra-write-lock-test-${process.pid}`);
const lockPath = () => path.join(ROOT, randomUUID(), 'w.lock');
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const ownerPath = (dir: string) => path.join(dir, 'owner.json');

afterAll(async () => {
  await fs.promises.rm(ROOT, { recursive: true }).catch(() => {});
});

describe('InterProcessWriteLock', () => {
  test('withLock serializes two holders on the same lock dir', async () => {
    const dir = lockPath();
    const a = new InterProcessWriteLock(dir, { pollMs: 5 });
    const b = new InterProcessWriteLock(dir, { pollMs: 5, staleMs: 60_000 });
    const events: string[] = [];
    const body = (tag: string) => async () => {
      events.push(`enter:${tag}`);
      await sleep(40);
      events.push(`exit:${tag}`);
    };

    const p1 = a.withLock(body('A'));
    await sleep(8); // let A win the token first
    const p2 = b.withLock(body('B'));
    await Promise.all([p1, p2]);

    // B cannot enter until A has exited — no interleaving.
    expect(events).toEqual(['enter:A', 'exit:A', 'enter:B', 'exit:B']);
  });

  test('release removes the lock dir when we still own it', async () => {
    const dir = lockPath();
    const lock = new InterProcessWriteLock(dir);
    const token = await lock.acquire();
    expect((await fs.promises.stat(dir)).isDirectory()).toBe(true);
    await lock.release(token);
    await expect(fs.promises.stat(dir)).rejects.toThrow();
  });

  test('acquire throws on timeout while another holder keeps the lock', async () => {
    const dir = lockPath();
    const a = new InterProcessWriteLock(dir);
    const b = new InterProcessWriteLock(dir, { timeoutMs: 60, pollMs: 10, staleMs: 60_000 });
    const token = await a.acquire('holder');
    await expect(b.acquire()).rejects.toThrow(/timed out/);
    await a.release(token);
  });

  test('steals a lock whose holder pid is dead', async () => {
    const dir = lockPath();
    await fs.promises.mkdir(dir, { recursive: true });
    const proc = Bun.spawn(['true']);
    await proc.exited; // pid is now dead
    await fs.promises.writeFile(ownerPath(dir), JSON.stringify({
      pid: proc.pid, host: os.hostname(), token: 'zombie', acquiredAt: Date.now(), op: 'crashed',
    }));

    const lock = new InterProcessWriteLock(dir, { timeoutMs: 1000, pollMs: 10, staleMs: 60_000 });
    const token = await lock.acquire('reclaim'); // dead pid ⇒ stale ⇒ stolen
    const owner = JSON.parse(await fs.promises.readFile(ownerPath(dir), 'utf8'));
    expect(owner.token).toBe(token);
    await lock.release(token);
  });

  test('steals a bare (owner-less) lock once it ages past staleMs', async () => {
    const dir = lockPath();
    await fs.promises.mkdir(dir, { recursive: true }); // no owner.json (mid-acquire crash)
    const lock = new InterProcessWriteLock(dir, { staleMs: 10, pollMs: 10, timeoutMs: 1000 });
    await sleep(25);
    const token = await lock.acquire();
    await lock.release(token);
    await expect(fs.promises.stat(dir)).rejects.toThrow();
  });

  test('release is a no-op when the lock was stolen out from under us', async () => {
    const dir = lockPath();
    const a = new InterProcessWriteLock(dir);
    const token = await a.acquire('held-too-long');
    // Simulate a successor that reclaimed the stale lock and now owns it.
    await fs.promises.writeFile(ownerPath(dir), JSON.stringify({
      pid: process.pid, host: os.hostname(), token: 'successor', acquiredAt: Date.now(),
    }));

    await a.release(token); // must NOT delete the successor's lock
    const owner = JSON.parse(await fs.promises.readFile(ownerPath(dir), 'utf8'));
    expect(owner.token).toBe('successor');
    await fs.promises.rm(dir, { recursive: true });
  });

  test('onContended fires once while a waiter is blocked', async () => {
    const dir = lockPath();
    const a = new InterProcessWriteLock(dir);
    let calls = 0;
    const b = new InterProcessWriteLock(dir, {
      pollMs: 5, staleMs: 60_000, onContended: () => { calls++; },
    });

    const token = await a.acquire();
    const waiter = b.withLock(async () => {});
    await sleep(25);
    await a.release(token);
    await waiter;
    expect(calls).toBe(1);
  });
});

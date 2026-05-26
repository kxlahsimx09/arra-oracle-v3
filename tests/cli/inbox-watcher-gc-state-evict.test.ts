// inbox-watcher.sh — gc_evict_terminal_state regression test (thread #224).
//
// gc_retire_terminal re-scans EVERY terminal state file each sweep. For ones
// whose worktree is already gone (`wt-already-gone`) or was owner-routed into
// a foreign wt (`owner-routed-foreign-wt`) the retire is a permanent no-op, so
// the state lingered forever and each sweep re-forked git/lsof over the pile —
// 555 such files fd-starved the watcher into a crash on 2026-05-16. This guards
// the reaper that deletes those once cold, while keeping (a) states that still
// pin a reclaimable worktree, (b) states whose source envelope is still queued
// (deleting would re-fire), and (c) states younger than STATE_TTL_DAYS.
//
// Hermetic: tmpdir state tree, stub thread-status + maw, no real worktrees.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "inbox-watcher.sh");
const FNAME = "2026-05-01_00-00_from-orchestrator_thread-1_dispatch.md";

let root: string;
let stateDir: string;
let inboxBase: string;
let apiDir: string;
let logFile: string;
let mawBin: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "iw-gc-evict-"));
  stateDir = join(root, "state");
  inboxBase = join(root, "inbox");
  apiDir = join(root, "api");
  logFile = join(root, "watcher.log");
  mkdirSync(join(stateDir, "state", "brew-ops"), { recursive: true });
  mkdirSync(join(inboxBase, "for-brew-ops"), { recursive: true });
  mkdirSync(join(apiDir, "thread"), { recursive: true });
  mawBin = join(root, "maw-stub.sh");
  writeFileSync(mawBin, "#!/usr/bin/env bash\nexit 0\n", { mode: 0o755 });
  writeFileSync(logFile, "");
});

afterEach(() => rmSync(root, { recursive: true, force: true }));

const statePath = () => join(stateDir, "state", "brew-ops", `${FNAME}.state`);

function writeState(fields: Record<string, string>) {
  const body = Object.entries(fields)
    .map(([k, v]) => `${k}=${v}`)
    .join("\n");
  writeFileSync(statePath(), body + "\n");
}

/** thread/1 reports `closed` so safe_to_retire's not-closed gate passes. */
function stubThreadClosed() {
  writeFileSync(join(apiDir, "thread", "1"), JSON.stringify({ thread: { status: "closed" } }));
}

function gcOnce(ttlDays: string) {
  return spawnSync("bash", [SCRIPT, "gc-once"], {
    env: {
      ...process.env,
      STATE_DIR: stateDir,
      INBOX_BASE: inboxBase,
      LOG_FILE: logFile,
      ORACLE_API: `file://${apiDir}`,
      MAW_BIN: `bash ${mawBin}`,
      CLAUDE_PROJECTS: join(root, "no-projects"),
      INBOX_AUTO_CLEAN: "1",
      STATE_TTL_DAYS: ttlDays,
    },
    encoding: "utf8",
  });
}

test("evicts a cold terminal state whose worktree is already gone", () => {
  writeState({
    oracle: "brew-ops", fname: FNAME, thread_id: "1", wake_key: "1",
    status: "completed", wt_path: join(root, "gone.wt-1-x"), // never created
  });
  expect(existsSync(statePath())).toBe(true);

  gcOnce("0"); // age 0 ≥ TTL 0 → eligible

  expect(existsSync(statePath())).toBe(false);
});

test("evicts a cold owner-routed terminal state without touching the foreign wt", () => {
  const foreignWt = join(root, "owner.wt-9-x");
  mkdirSync(foreignWt, { recursive: true });
  writeState({
    oracle: "brew-ops", fname: FNAME, thread_id: "1", wake_key: "1",
    status: "completed", route: "owner_send_keys", wt_path: foreignWt,
  });

  gcOnce("0");

  expect(existsSync(statePath())).toBe(false); // state reaped …
  expect(existsSync(foreignWt)).toBe(true); // … foreign wt left intact
});

test("keeps a terminal state whose worktree still exists and is pending retire", () => {
  // Worktree on disk, thread NOT closed (no stub) → gc_retire_terminal skips,
  // so gc_evict_terminal_state must also keep it (retire still owns it).
  const wt = join(root, "live.wt-2-x");
  mkdirSync(wt, { recursive: true });
  writeState({
    oracle: "brew-ops", fname: FNAME, thread_id: "1", wake_key: "1",
    status: "completed", wt_path: wt,
  });

  gcOnce("0");

  expect(existsSync(statePath())).toBe(true);
});

test("keeps a terminal state whose source envelope is still queued (re-fire guard)", () => {
  writeState({
    oracle: "brew-ops", fname: FNAME, thread_id: "1", wake_key: "1",
    status: "completed", wt_path: join(root, "gone.wt-1-x"),
  });
  writeFileSync(join(inboxBase, "for-brew-ops", FNAME), "envelope still here\n");

  gcOnce("0");

  expect(existsSync(statePath())).toBe(true);
});

test("keeps a terminal state younger than STATE_TTL_DAYS", () => {
  writeState({
    oracle: "brew-ops", fname: FNAME, thread_id: "1", wake_key: "1",
    status: "completed", wt_path: join(root, "gone.wt-1-x"),
  });

  gcOnce("9999"); // freshly written → age 0 < TTL → kept

  expect(existsSync(statePath())).toBe(true);
});

test("evicts a retired terminal state (worktree already reclaimed)", () => {
  stubThreadClosed();
  writeState({
    oracle: "brew-ops", fname: FNAME, thread_id: "1", wake_key: "1",
    status: "completed", wt_path: join(root, "gone.wt-1-x"), retired_at: "1700000000",
  });

  gcOnce("0");

  expect(existsSync(statePath())).toBe(false);
});

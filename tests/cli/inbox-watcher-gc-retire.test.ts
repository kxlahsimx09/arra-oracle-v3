// inbox-watcher.sh — gc worktree-retire regression test.
//
// Guards the repo-path bug in maybe_retire_worktree: `git worktree remove`
// was invoked with `-C "$wt_path/.."`. maw creates worktrees as SIBLINGS of
// the main checkout (`<repo>.wt-42-…` next to `<repo>`), so `$wt_path/..` is
// the directory that *holds both* — not a git repo — and the remove returned
// nonzero on EVERY retire. The gc reclaimed zero worktrees: every state file
// stuck at `ret=no` (audited on thread #162). The fix derives the main repo
// as `${wt_path%.wt-*}`, matching discover_repos.
//
// Hermetic: a real throwaway git repo + sibling worktree under a tmpdir, a
// file:// thread-status stub, a no-op maw stub. No real worktrees, no
// network, no claude processes touched.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
  mkdirSync,
  existsSync,
  readFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "inbox-watcher.sh");
const STATE_NAME = "2026-05-18_00-00_from-orchestrator_thread-1_dispatch.md.state";

let root: string;
let repo: string;
let worktree: string;
let stateDir: string;
let apiDir: string;
let logFile: string;
let mawBin: string;

function git(cwd: string, ...args: string[]) {
  const r = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr}`);
  return r.stdout.trim();
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "iw-gc-"));
  repo = join(root, "demo-repo");
  worktree = join(root, "demo-repo.wt-1-inbox-test"); // SIBLING of repo
  stateDir = join(root, "state");
  apiDir = join(root, "api");
  logFile = join(root, "watcher.log");

  // Throwaway git repo with one commit.
  mkdirSync(repo, { recursive: true });
  git(repo, "init", "-q", "-b", "main");
  git(repo, "config", "user.email", "t@test");
  git(repo, "config", "user.name", "t");
  writeFileSync(join(repo, "README.md"), "demo\n");
  git(repo, "add", "-A");
  git(repo, "commit", "-q", "-m", "init");
  // Linked worktree created as a sibling — mirrors maw's layout.
  git(repo, "worktree", "add", "-q", "-b", "agents/1-inbox-test", worktree);

  mkdirSync(join(stateDir, "state", "brew-ops"), { recursive: true });
  mkdirSync(join(stateDir, "sessions"), { recursive: true });

  // file:// thread-status stub — thread/1 reports `closed`.
  mkdirSync(join(apiDir, "thread"), { recursive: true });
  writeFileSync(
    join(apiDir, "thread", "1"),
    JSON.stringify({ thread: { status: "closed" } }),
  );

  // no-op maw stub (ls emits nothing → tmux-kill path is never taken).
  mawBin = join(root, "maw-stub.sh");
  writeFileSync(mawBin, "#!/usr/bin/env bash\nexit 0\n", { mode: 0o755 });

  writeFileSync(logFile, "");
});

afterEach(() => {
  // The worktree may already be removed by the test; prune admin state anyway.
  spawnSync("git", ["-C", repo, "worktree", "prune"], { encoding: "utf8" });
  rmSync(root, { recursive: true, force: true });
});

/** Write a `<oracle>/<fname>.state` file. */
function writeState(fields: Record<string, string>) {
  const body = Object.entries(fields)
    .map(([k, v]) => `${k}=${v}`)
    .join("\n");
  writeFileSync(join(stateDir, "state", "brew-ops", STATE_NAME), body + "\n");
}

/** A `completed` envelope state pointing at the sibling worktree. */
function completedState(): Record<string, string> {
  return {
    oracle: "brew-ops",
    fname: STATE_NAME.replace(/\.state$/, ""),
    thread_id: "1",
    wake_key: "1",
    wt_suffix: "inbox-test",
    status: "completed",
    wt_path: worktree,
  };
}

/** Run a single GC sweep with the temp environment wired in. */
function gcOnce() {
  return spawnSync("bash", [SCRIPT, "gc-once"], {
    env: {
      ...process.env,
      STATE_DIR: stateDir,
      LOG_FILE: logFile,
      ORACLE_API: `file://${apiDir}`,
      MAW_BIN: `bash ${mawBin}`,
      CLAUDE_PROJECTS: join(root, "no-projects"),
      INBOX_AUTO_CLEAN: "1",
    },
    encoding: "utf8",
  });
}

function stateBody() {
  return readFileSync(join(stateDir, "state", "brew-ops", STATE_NAME), "utf8");
}

test("gc retires a completed envelope's clean worktree (sibling-layout repo path)", () => {
  writeState(completedState());
  expect(existsSync(worktree)).toBe(true);

  gcOnce();

  // The worktree directory is gone …
  expect(existsSync(worktree)).toBe(false);
  // … and the retire is stamped on the state file.
  expect(stateBody()).toContain("retired_at=");
});

test("gc keeps a worktree with uncommitted work (safe_to_retire dirty gate)", () => {
  writeFileSync(join(worktree, "wip.txt"), "uncommitted\n");
  writeState(completedState());

  gcOnce();

  // Dirty tree → not retired, no stamp.
  expect(existsSync(worktree)).toBe(true);
  expect(stateBody()).not.toContain("retired_at=");
});

test("gc keeps a worktree whose thread is not closed", () => {
  // thread/2 has no stub file → thread_status is empty → not `closed`.
  writeState({ ...completedState(), thread_id: "2", wake_key: "2" });

  gcOnce();

  expect(existsSync(worktree)).toBe(true);
  expect(stateBody()).not.toContain("retired_at=");
});

// ─── #164 — terminal-failure envelopes are retired too ────────────────────
//
// gc_retire_terminal originally iterated `status=completed` only, so a
// `failed_no_prompt` / `failed_stuck` envelope kept its worktree forever:
// the state file still references it, so gc_prune_orphan_worktrees skips it
// as well. Observed leaks: wt-9 (failed_no_prompt), wt-50 (failed_stuck).
// The gate (safe_to_retire) is unchanged — failure envelopes are retired on
// EXACTLY the same conditions as completed ones, no looser.

test("gc retires a failed_stuck envelope's clean worktree (#164 terminal-failure leak)", () => {
  writeState({ ...completedState(), status: "failed_stuck" });
  expect(existsSync(worktree)).toBe(true);

  gcOnce();

  expect(existsSync(worktree)).toBe(false);
  expect(stateBody()).toContain("retired_at=");
});

test("gc keeps a failed_no_prompt envelope whose thread is not closed", () => {
  // Same thread-not-closed gate as completed — terminal-failure does not
  // bypass safe_to_retire. thread/2 has no stub → status empty → not closed.
  writeState({
    ...completedState(),
    status: "failed_no_prompt",
    thread_id: "2",
    wake_key: "2",
  });

  gcOnce();

  expect(existsSync(worktree)).toBe(true);
  expect(stateBody()).not.toContain("retired_at=");
});

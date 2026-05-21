// inbox-watcher.sh — Path 1 pre-resume fetch (thread #199, parent #181).
//
// maw createWorktree fetches + fast-forwards local default branch on --fresh
// spawn (maw-js PR #8). But Path 1 reuses an existing worktree without
// re-fetching — a long-lived campaign session that --resume's 3+ times
// without re-fetching hits the same stale-base trap from the other direction
// (wt-48 / PR #215 was incident #3 from the OTHER direction — fresh spawn
// with stale local main). This guards the symmetric infra fix.
//
// Reproduction shape: build a real bare "remote" + a local repo whose `main`
// is intentionally stuck at the older commit; pre-seed Path 1 reuse state;
// drop a same-campaign envelope; assert the local repo's `main` ref advanced
// before --resume fired.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "inbox-watcher.sh");

let root: string;
let inboxBase: string;
let stateDir: string;
let mawLog: string;
let priorWt: string;
let staleSha: string;
let advancedSha: string;

function sh(cmd: string, cwd?: string) {
  const r = spawnSync("bash", ["-c", cmd], { cwd, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`cmd failed: ${cmd}\n${r.stdout}\n${r.stderr}`);
  return r.stdout.trim();
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "iw-prefetch-"));
  inboxBase = join(root, "inbox");
  stateDir = join(root, "state");
  mawLog = join(root, "maw-calls.log");
  mkdirSync(join(inboxBase, "for-orchestrator"), { recursive: true });
  mkdirSync(stateDir, { recursive: true });

  // Build a real git "remote" + local clone whose `main` is stuck at the
  // older commit (mimics §3c primary parked on a non-default branch with
  // local main never fast-forwarded).
  const remote = join(root, "remote.git");
  const local = join(root, "local");
  sh(`git init --bare -b main '${remote}' >/dev/null 2>&1`);

  const seed = join(root, "seed");
  sh(`git init -b main '${seed}' >/dev/null && cd '${seed}' && git -c user.email=t@t -c user.name=t commit --allow-empty -m stale -q && git push '${remote}' main:main -q`);
  staleSha = sh(`git -C '${seed}' rev-parse HEAD`);

  sh(`git clone '${remote}' '${local}' -q`);
  sh(`git -C '${local}' remote set-head origin main`);

  // Park the local primary on a non-default integration branch (mirrors §3c
  // discipline). This lets us check `main` out in the prior worktree.
  sh(`git -C '${local}' checkout -b feat/all-prs-rebased -q`);

  // Advance the remote one commit AFTER local's last fetch — this is the
  // freshness gap the prior wt would otherwise miss.
  sh(`cd '${seed}' && git -c user.email=t@t -c user.name=t commit --allow-empty -m advance -q && git push '${remote}' main:main -q`);
  advancedSha = sh(`git -C '${seed}' rev-parse main`);

  // Pre-existing worktree off `main` — what Path 1 would resume into.
  priorWt = join(root, "fake.wt-7-inbox-prev");
  sh(`git -C '${local}' worktree add '${priorWt}' main -q`);

  // Pre-seed Path 1 reuse state: session-id + a terminal state file pointing
  // at priorWt with wake_key matching the new envelope's parent_thread.
  const sessDir = join(stateDir, "sessions", "orchestrator");
  mkdirSync(sessDir, { recursive: true });
  writeFileSync(join(sessDir, "thread-1000.session-id"), "SID-PREFETCH\n");
  const stDir = join(stateDir, "state", "orchestrator");
  mkdirSync(stDir, { recursive: true });
  writeFileSync(
    join(stDir, "prev.state"),
    ["fired_at=1", "oracle=orchestrator", "fname=prev.md", "thread_id=999",
      "wake_key=1000", `wt_path=${priorWt}`, "status=completed"].join("\n") + "\n",
  );

  // Stub maw: record + emit a worktree line so wt_path extraction succeeds.
  const stub = join(root, "maw-stub.sh");
  writeFileSync(
    stub,
    `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${mawLog}"\n` +
      `echo "+ worktree: ${priorWt} (main)"\nexit 0\n`,
    { mode: 0o755 },
  );
  writeFileSync(mawLog, "");
  process.env.__IW_MAW = `bash ${stub}`;
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

function envelope(thread: number, parentThread: number, fname: string) {
  const lines = [
    "---",
    "from: next-impl",
    "to: orchestrator",
    "type: reply",
    `thread: ${thread}`,
    `parent_thread: ${parentThread}`,
    "created: 2026-05-21T22:00:00+07:00",
    "---",
    "",
    "body",
  ];
  writeFileSync(join(inboxBase, "for-orchestrator", fname), lines.join("\n"));
}

function scanOnce() {
  return spawnSync("bash", [SCRIPT, "scan-once"], {
    env: {
      ...process.env,
      INBOX_BASE: inboxBase,
      STATE_DIR: stateDir,
      MAW_BIN: process.env.__IW_MAW!,
      INBOX_POLL_INTERVAL: "1",
    },
    encoding: "utf8",
  });
}

// Per-test timeout bump — setup builds two real git repos + a worktree + a
// remote fetch, so the default 5s budget is too tight.
const TEST_TIMEOUT_MS = 30_000;

test("Path 1 reuse fast-forwards prior wt's local main BEFORE firing --resume (thread #199 FIX 4)", () => {
  // Before scan: prior wt's local main is at stale commit.
  expect(sh(`git -C '${priorWt}' rev-parse main`)).toBe(staleSha);

  envelope(1001, 1000, "2026-05-21_22-00_from-next-impl_thread-1001_reply.md");

  const r = scanOnce();
  expect(r.status).toBe(0);

  // After scan: prior wt's local main is now at the advanced commit
  // (fetch + update-ref ran in the Path 1 pre-resume hook).
  expect(sh(`git -C '${priorWt}' rev-parse main`)).toBe(advancedSha);

  // And the watcher fired --resume into that worktree (not --fresh).
  expect(readFileSync(mawLog, "utf8")).toContain("--resume SID-PREFETCH");
}, TEST_TIMEOUT_MS);

test("missing origin/HEAD in prior wt does not block resume (graceful degradation)", () => {
  // Tear down origin/HEAD on the local repo (and prior wt shares its refs).
  sh(`git -C '${priorWt}' symbolic-ref -d refs/remotes/origin/HEAD`);

  envelope(1101, 1100, "2026-05-21_22-05_from-next-impl_thread-1101_reply.md");

  // Re-seed under a fresh wake_key so the second test owns its state.
  const sessDir = join(stateDir, "sessions", "orchestrator");
  writeFileSync(join(sessDir, "thread-1100.session-id"), "SID-PREFETCH2\n");
  const stDir = join(stateDir, "state", "orchestrator");
  writeFileSync(
    join(stDir, "prev2.state"),
    ["fired_at=1", "oracle=orchestrator", "fname=prev2.md", "thread_id=1099",
      "wake_key=1100", `wt_path=${priorWt}`, "status=completed"].join("\n") + "\n",
  );

  const r = scanOnce();
  expect(r.status).toBe(0);

  // Resume still fired even though the pre-fetch could not determine the
  // default branch (offline-equivalent fall-through).
  expect(readFileSync(mawLog, "utf8")).toContain("--resume SID-PREFETCH2");
}, TEST_TIMEOUT_MS);

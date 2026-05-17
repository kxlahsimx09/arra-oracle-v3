// inbox-watcher.sh — dispatch-side sticky routing / dedup (§153) regression.
//
// Guards the wt-43/wt-46 incident (thread #151): a 2nd dispatch envelope for
// the same (worker_oracle, parent_thread) reaching a busy worker used to
// --fresh-spawn a sibling worker session. PR #75 made REPLY routing sticky to
// the owner session; §153 mirrors it onto the dispatch/worker-receiving side:
//
//   - owner record present  → §151 owner routing (oracle-agnostic) defers /
//                              send-keys / --resume — never a sibling;
//   - owner record absent    → the §11k/§153 parent_session_busy fallback,
//                              now un-gated from the orchestrator, defers a
//                              same-campaign sibling for EVERY oracle.
//
// Hermetic scan-once: a stub `maw` records every wake; no real worktrees or
// claude processes. The live tmux send-keys delivery (owner idle case) is the
// §5(a)-accepted residual — not integration-tested here, as in PR #75.

import { test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "scripts", "inbox-watcher.sh");

let root: string;
let inboxBase: string;
let stateDir: string;
let mawLog: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "iw-dispatch-"));
  inboxBase = join(root, "inbox");
  stateDir = join(root, "state");
  mawLog = join(root, "maw-calls.log");
  mkdirSync(join(inboxBase, "for-brew-ops"), { recursive: true });
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(mawLog, "");
  // Default stub: emits a worktree line so fire_wake records an owner.
  process.env.__IW_MAW = `bash ${makeStub(true)}`;
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

/** Write a maw stub; `withWorktree` controls whether it emits a parseable
 *  `+ worktree:` line (absent line ⇒ fire_wake records no owner — the §153
 *  §2 fallback path). */
function makeStub(withWorktree: boolean): string {
  const stub = join(root, `maw-stub-${withWorktree}.sh`);
  const wt = withWorktree
    ? `echo "+ worktree: ${root}/fake.wt-1-stub (branch)"\n`
    : `echo "woke session (no worktree line)"\n`;
  writeFileSync(stub, `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${mawLog}"\n${wt}exit 0\n`, {
    mode: 0o755,
  });
  return stub;
}

/** Write a dispatch envelope into for-<oracle>/. */
function dispatch(oracle: string, name: string, thread: number, parentThread: number) {
  const lines = [
    "---",
    "from: orchestrator",
    `to: ${oracle}`,
    "type: dispatch",
    `thread: ${thread}`,
    `parent_thread: ${parentThread}`,
    "parent_oracle: orchestrator",
    "created: 2026-05-17T15:00:00+07:00",
    "---",
    "",
    "body",
  ];
  writeFileSync(join(inboxBase, `for-${oracle}`, name), lines.join("\n"));
}

/** Run one scan pass with the temp env wired in. */
function scanOnce() {
  return spawnSync("bash", [SCRIPT, "scan-once"], {
    env: {
      ...process.env,
      INBOX_BASE: inboxBase,
      STATE_DIR: stateDir,
      MAW_BIN: process.env.__IW_MAW,
      INBOX_POLL_INTERVAL: "1",
    },
    encoding: "utf8",
  });
}

function mawCalls(): string {
  return readFileSync(mawLog, "utf8");
}

/** Count `maw wake` invocations recorded by the stub. */
function fireCount(): number {
  return mawCalls()
    .split("\n")
    .filter((l) => l.includes("wake ")).length;
}

/** Map of envelope filename → status, read from the state files. */
function states(oracle: string): Record<string, string> {
  const dir = join(stateDir, "state", oracle);
  const out: Record<string, string> = {};
  let files: string[] = [];
  try {
    files = readdirSync(dir);
  } catch {
    return out;
  }
  for (const f of files) {
    if (!f.endsWith(".state")) continue;
    const m = readFileSync(join(dir, f), "utf8").match(/^status=(.*)$/m);
    out[f.replace(/\.state$/, "")] = m ? m[1] : "?";
  }
  return out;
}

function ownerPath(oracle: string, key: number): string {
  return join(stateDir, "sessions", oracle, `thread-${key}.owner`);
}

test("single dispatch to an idle worker → one --fresh wake, owner recorded", () => {
  dispatch("brew-ops", "2026-05-17_15-01_from-orchestrator_thread-400_dispatch.md", 400, 400);
  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(1);
  expect(mawCalls()).toContain("--fresh");
  expect(Object.values(states("brew-ops"))).toEqual(["fired"]);
  // fire_wake records the worker as its own campaign owner.
  expect(readFileSync(ownerPath("brew-ops", 400), "utf8").trim()).toBe(`${root}/fake.wt-1-stub`);
});

test("two dispatches, one campaign, one scan → one fires, one defers (coalesce / no-sibling)", () => {
  dispatch("brew-ops", "2026-05-17_15-01_from-orchestrator_thread-401_dispatch.md", 401, 400);
  dispatch("brew-ops", "2026-05-17_15-02_from-orchestrator_thread-402_dispatch.md", 402, 400);
  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(1);
  expect(Object.values(states("brew-ops")).sort()).toEqual(["deferred", "fired"]);
});

test("no-owner-record fallback: busy worker still dedups, no sibling (§153 §2)", () => {
  // Stub emits no worktree line ⇒ the 1st dispatch's fire_wake records no
  // owner. The 2nd must still defer via the parent_session_busy fallback —
  // which §153 un-gated from the orchestrator. Pre-§153 this fired a sibling.
  process.env.__IW_MAW = `bash ${makeStub(false)}`;
  dispatch("brew-ops", "2026-05-17_15-01_from-orchestrator_thread-411_dispatch.md", 411, 410);
  dispatch("brew-ops", "2026-05-17_15-02_from-orchestrator_thread-412_dispatch.md", 412, 410);
  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(1);
  expect(Object.values(states("brew-ops")).sort()).toEqual(["deferred", "fired"]);
});

test("dispatches under different parent_thread are distinct campaigns → both fire", () => {
  dispatch("brew-ops", "2026-05-17_15-01_from-orchestrator_thread-421_dispatch.md", 421, 420);
  dispatch("brew-ops", "2026-05-17_15-02_from-orchestrator_thread-431_dispatch.md", 431, 430);
  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(2);
  expect(Object.values(states("brew-ops")).sort()).toEqual(["fired", "fired"]);
});

test("2nd dispatch defers behind an in-flight sibling state (busy→defer)", () => {
  // Pre-seed a sibling already `fired` for campaign 440 (no owner record) —
  // parent_session_busy's state-file branch must defer the new dispatch.
  const stDir = join(stateDir, "state", "brew-ops");
  mkdirSync(stDir, { recursive: true });
  writeFileSync(
    join(stDir, "sibling.state"),
    ["fired_at=1", "oracle=brew-ops", "fname=sibling.md", "thread_id=441",
      "wake_key=440", "status=fired"].join("\n") + "\n",
  );
  dispatch("brew-ops", "2026-05-17_15-02_from-orchestrator_thread-442_dispatch.md", 442, 440);
  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(0);
  expect(states("brew-ops")["2026-05-17_15-02_from-orchestrator_thread-442_dispatch.md"]).toBe(
    "deferred",
  );
});

test("dispatch with a prior idle session → --resume, no sibling", () => {
  // Prior campaign-450 worker: session-id mapped + a terminal state carrying
  // wake_key=450 and a worktree dir with no live claude → fire_wake Path 1
  // resumes that session instead of spawning a sibling.
  const wt = join(root, "fake.wt-7-prev");
  mkdirSync(wt, { recursive: true });
  const sessDir = join(stateDir, "sessions", "brew-ops");
  mkdirSync(sessDir, { recursive: true });
  writeFileSync(join(sessDir, "thread-450.session-id"), "SID-WORKER\n");
  const stDir = join(stateDir, "state", "brew-ops");
  mkdirSync(stDir, { recursive: true });
  writeFileSync(
    join(stDir, "prev.state"),
    ["fired_at=1", "oracle=brew-ops", "fname=prev.md", "thread_id=449",
      "wake_key=450", `wt_path=${wt}`, "status=completed"].join("\n") + "\n",
  );
  dispatch("brew-ops", "2026-05-17_15-05_from-orchestrator_thread-451_dispatch.md", 451, 450);
  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(mawCalls()).toContain("--resume SID-WORKER");
});

test("deferred dispatch un-defers once the campaign session goes terminal", () => {
  dispatch("brew-ops", "2026-05-17_15-01_from-orchestrator_thread-461_dispatch.md", 461, 460);
  dispatch("brew-ops", "2026-05-17_15-02_from-orchestrator_thread-462_dispatch.md", 462, 460);

  scanOnce(); // 461 fires, 462 defers
  expect(fireCount()).toBe(1);

  // Drive the fired sibling to terminal — the campaign session has finished.
  const dir = join(stateDir, "state", "brew-ops");
  const firstSf = readdirSync(dir).find((f) => f.includes("thread-461"))!;
  const p = join(dir, firstSf);
  writeFileSync(p, readFileSync(p, "utf8").replace(/^status=.*$/m, "status=completed"));

  scanOnce(); // 462 un-defers and fires (Path 1 would --resume the campaign)
  expect(fireCount()).toBe(2);
});

test("owner record pointing at a vanished worktree → --fresh respawn + ownership transfer", () => {
  const sessDir = join(stateDir, "sessions", "brew-ops");
  mkdirSync(sessDir, { recursive: true });
  writeFileSync(ownerPath("brew-ops", 470), `${root}/gone.wt-9-vanished\n`);
  dispatch("brew-ops", "2026-05-17_15-01_from-orchestrator_thread-471_dispatch.md", 471, 470);
  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(1);
  expect(mawCalls()).toContain("--fresh");
  // Ownership transferred to the freshly-spawned worktree.
  expect(readFileSync(ownerPath("brew-ops", 470), "utf8").trim()).toBe(`${root}/fake.wt-1-stub`);
});

// inbox-watcher.sh — orchestrator fan-out dedup (§11k) regression tests.
//
// Guards the 2026-05-16 triple-dispatch incident (thread #134 / #348): three
// fan-out reply envelopes sharing a parent_thread used to each --fresh-spawn
// a separate orchestrator session. The watcher now keys the wake on
// parent_thread and DEFERS same-parent siblings behind one live session.
//
// Hermetic: a stub `maw` records every `wake` call; no real worktrees or
// claude processes are touched (parent_session_busy's claude_alive_at branch
// is only reached when a session-id file exists — never in a fresh STATE_DIR).

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
  root = mkdtempSync(join(tmpdir(), "iw-dedup-"));
  inboxBase = join(root, "inbox");
  stateDir = join(root, "state");
  mawLog = join(root, "maw-calls.log");
  mkdirSync(join(inboxBase, "for-orchestrator"), { recursive: true });
  mkdirSync(join(inboxBase, "for-brew-ops"), { recursive: true });
  mkdirSync(stateDir, { recursive: true });

  // Stub maw: append the arg vector to mawLog, emit a fake worktree line so
  // wt_path extraction succeeds, exit 0.
  const stub = join(root, "maw-stub.sh");
  writeFileSync(
    stub,
    `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "${mawLog}"\n` +
      `echo "+ worktree: ${root}/fake.wt-1-stub (branch)"\nexit 0\n`,
    { mode: 0o755 },
  );
  writeFileSync(mawLog, "");
  process.env.__IW_MAW = `bash ${stub}`;
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

/** Write an envelope into for-<oracle>/. */
function envelope(
  oracle: string,
  name: string,
  fields: { thread?: number; parentThread?: number },
) {
  const lines = ["---", `from: next-impl`, `to: ${oracle}`, "type: reply"];
  if (fields.thread !== undefined) lines.push(`thread: ${fields.thread}`);
  if (fields.parentThread !== undefined) lines.push(`parent_thread: ${fields.parentThread}`);
  lines.push("created: 2026-05-16T19:00:00+07:00", "---", "", "body");
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

/** Count `maw wake` invocations recorded by the stub. */
function fireCount(): number {
  return readFileSync(mawLog, "utf8").split("\n").filter((l) => l.includes("wake ")).length;
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
    const txt = readFileSync(join(dir, f), "utf8");
    const m = txt.match(/^status=(.*)$/m);
    out[f.replace(/\.state$/, "")] = m ? m[1] : "?";
  }
  return out;
}

test("three fan-out replies sharing parent_thread → exactly one fires, rest defer", () => {
  // Distinct sub-threads (501/502/503), one campaign (parent 500).
  envelope("orchestrator", "2026-05-16_19-01_from-next-impl_thread-501_reply.md", { thread: 501, parentThread: 500 });
  envelope("orchestrator", "2026-05-16_19-02_from-next-impl_thread-502_reply.md", { thread: 502, parentThread: 500 });
  envelope("orchestrator", "2026-05-16_19-03_from-next-impl_thread-503_reply.md", { thread: 503, parentThread: 500 });

  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(1);
  const st = Object.values(states("orchestrator")).sort();
  expect(st).toEqual(["deferred", "deferred", "fired"]);
});

test("replies under DIFFERENT parent_thread are distinct campaigns → both fire", () => {
  envelope("orchestrator", "2026-05-16_19-01_from-next-impl_thread-601_reply.md", { thread: 601, parentThread: 600 });
  envelope("orchestrator", "2026-05-16_19-02_from-next-impl_thread-611_reply.md", { thread: 611, parentThread: 610 });

  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(2);
  expect(Object.values(states("orchestrator")).sort()).toEqual(["fired", "fired"]);
});

test("non-orchestrator envelopes are never deferred (no fan-out dedup)", () => {
  // Two envelopes to brew-ops, different threads — both must fire.
  envelope("brew-ops", "2026-05-16_19-01_from-next-impl_thread-701_reply.md", { thread: 701, parentThread: 700 });
  envelope("brew-ops", "2026-05-16_19-02_from-next-impl_thread-702_reply.md", { thread: 702, parentThread: 700 });

  const r = scanOnce();
  expect(r.status).toBe(0);

  expect(fireCount()).toBe(2);
  expect(Object.values(states("brew-ops")).sort()).toEqual(["fired", "fired"]);
});

test("orchestrator envelope without parent_thread keys on its own thread → fires", () => {
  envelope("orchestrator", "2026-05-16_19-01_from-user_thread-800_consult.md", { thread: 800 });
  const r = scanOnce();
  expect(r.status).toBe(0);
  expect(fireCount()).toBe(1);
  expect(Object.values(states("orchestrator"))).toEqual(["fired"]);
});

test("deferred sibling stays deferred while the campaign session is in-flight", () => {
  envelope("orchestrator", "2026-05-16_19-01_from-next-impl_thread-901_reply.md", { thread: 901, parentThread: 900 });
  envelope("orchestrator", "2026-05-16_19-02_from-next-impl_thread-902_reply.md", { thread: 902, parentThread: 900 });

  scanOnce();
  scanOnce(); // second pass — first envelope still `fired` (no JSONL, T1 not elapsed)

  expect(fireCount()).toBe(1);
  expect(Object.values(states("orchestrator")).sort()).toEqual(["deferred", "fired"]);
});

test("new reply resumes the parent campaign's idle session (keyed on parent_thread)", () => {
  // Pre-seed a prior campaign: session-id mapped under the PARENT thread
  // (1000), a terminal state file carrying wake_key=1000 + its worktree path.
  const wt = join(root, "fake.wt-7-inbox-prev");
  mkdirSync(wt, { recursive: true });
  const sessDir = join(stateDir, "sessions", "orchestrator");
  mkdirSync(sessDir, { recursive: true });
  writeFileSync(join(sessDir, "thread-1000.session-id"), "SID-ABC\n");
  const stDir = join(stateDir, "state", "orchestrator");
  mkdirSync(stDir, { recursive: true });
  writeFileSync(
    join(stDir, "prev.state"),
    ["fired_at=1", "oracle=orchestrator", "fname=prev.md", "thread_id=999",
      "wake_key=1000", `wt_path=${wt}`, "status=completed"].join("\n") + "\n",
  );

  // A fresh reply on a NEW sub-thread (1001) but the SAME campaign (1000).
  envelope("orchestrator", "2026-05-16_20-00_from-next-impl_thread-1001_reply.md", { thread: 1001, parentThread: 1000 });
  const r = scanOnce();
  expect(r.status).toBe(0);

  // No live claude at the (fake) worktree → the idle session is reused.
  const calls = readFileSync(mawLog, "utf8");
  expect(calls).toContain("--resume SID-ABC");
});

test("deferred envelope un-defers once the campaign session goes terminal", () => {
  envelope("orchestrator", "2026-05-16_19-01_from-next-impl_thread-911_reply.md", { thread: 911, parentThread: 910 });
  envelope("orchestrator", "2026-05-16_19-02_from-next-impl_thread-912_reply.md", { thread: 912, parentThread: 910 });

  scanOnce(); // 911 fires, 912 defers
  expect(fireCount()).toBe(1);

  // Simulate the campaign session finishing: drive 911's state to terminal.
  const dir = join(stateDir, "state", "orchestrator");
  const firstSf = readdirSync(dir).find((f) => f.includes("thread-911"))!;
  const p = join(dir, firstSf);
  writeFileSync(p, readFileSync(p, "utf8").replace(/^status=.*$/m, "status=completed"));

  scanOnce(); // 912 should now un-defer and fire (Path 1 would --resume)
  expect(fireCount()).toBe(2);
  expect(states("orchestrator")[firstSf.replace(/\.state$/, "")]).toBe("completed");
});
